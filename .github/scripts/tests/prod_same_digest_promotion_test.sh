#!/usr/bin/env bash
# TC-10 (plan §7, GAP-16): PROD promotes only the image digests a successful
# UAT Hybrid run accepted. UAT failure/pending, digest mismatch and main→prod
# must all be refused; a successful UAT manifest is forwarded unchanged.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
verifier="${repo_root}/.github/scripts/snapshots/verify-promotion-manifest.py"
prod_dispatcher="${repo_root}/.github/scripts/snapshots/dispatch-prod-combined.sh"
promote="${repo_root}/.github/scripts/serverless/promote_image_by_digest.sh"
verify_revision="${repo_root}/.github/scripts/serverless/verify_cloud_run_image_digest.sh"
preflight="${repo_root}/.github/scripts/serverless/validate_promotion_manifest.sh"
work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

digest_a="sha256:$(printf 'a%.0s' {1..64})"
digest_b="sha256:$(printf 'b%.0s' {1..64})"
sha="$(printf 'c%.0s' {1..40})"
image() { printf 'asia-east1-docker.pkg.dev/open-platform-uat/serverless/%s' "$1"; }

write_manifest() {
  jq -n --arg tag "${2:-daily-build-2026.10.01-r1}" --arg run "${3:-4242}" \
    --arg da "${4:-${digest_a}}" --arg sha "${sha}" \
    --arg ia "$(image accounts)" --arg ib "$(image billing-service)" --arg ic "$(image content-service)" \
    '{schema:1, environment:"uat", snapshot_tag:$tag, uat_run_id:$run, images:[
      {service:"accounts", image:$ia, tag:$tag, digest:$da, source_repository:"ai-workspace-services/accounts", source_sha:$sha},
      {service:"billing-service", image:$ib, tag:$tag, digest:$da, source_repository:"ai-workspace-services/billing-service", source_sha:$sha},
      {service:"content-service", image:$ic, tag:$tag, digest:$da, source_repository:"ai-workspace-services/content-service", source_sha:$sha}]}' > "$1"
  jq -f "${repo_root}/.github/scripts/tests/fixtures/uat-upgrade-acceptance.jq" "$1" > "$1.proof"
  mv "$1.proof" "$1"
}
write_run() {
  jq -n --arg status "${2:-completed}" --arg conclusion "${3:-success}" --arg path "${4:-.github/workflows/hybrid-orchestrator.yml}" \
    '{id:4242, path:$path, head_branch:"main", event:"workflow_dispatch", status:$status, conclusion:(if $conclusion == "" then null else $conclusion end)}' > "$1"
}

# --- validator --------------------------------------------------------------
write_manifest "${work}/good.json"
write_run "${work}/run-ok.json"
normalized="$(python3 "${verifier}" --manifest "${work}/good.json" --snapshot-tag daily-build-2026.10.01-r1 \
  --uat-run-json "${work}/run-ok.json" --release-tag v2026.10.01-r1)" || fail "a successful UAT manifest must be accepted"
jq -e --arg d "${digest_a}" '.uat_run_id == "4242" and ([.images[].digest] | unique == [$d])' <<<"${normalized}" >/dev/null \
  || fail "the normalized manifest must keep the UAT run and digests"

refuse() {
  local why="$1"; shift
  if python3 "${verifier}" "$@" >/dev/null 2>"${work}/refused.err"; then fail "${why} must be refused"; fi
  grep -q 'Refusing PROD promotion' "${work}/refused.err" || fail "${why}: refusal must explain itself"
}
write_run "${work}/run-pending.json" in_progress ""
refuse "a pending UAT run" --manifest "${work}/good.json" --uat-run-json "${work}/run-pending.json"
write_run "${work}/run-failed.json" completed failure
refuse "a failed UAT run" --manifest "${work}/good.json" --uat-run-json "${work}/run-failed.json"
write_run "${work}/run-other.json" completed success .github/workflows/serverless-orchestrator.yml
refuse "evidence from a non-Hybrid run" --manifest "${work}/good.json" --uat-run-json "${work}/run-other.json"
write_manifest "${work}/main.json" main
refuse "a manifest built from main" --manifest "${work}/main.json" --uat-run-json "${work}/run-ok.json"
refuse "a PROD release from main" --manifest "${work}/good.json" --release-tag main --uat-run-json "${work}/run-ok.json"
refuse "a different UAT snapshot" --manifest "${work}/good.json" --snapshot-tag daily-build-2026.09.30-r1
refuse "a different UAT run" --manifest "${work}/good.json" --uat-run-id 4243
write_manifest "${work}/bad-digest.json" daily-build-2026.10.01-r1 4242 "sha256:abc"
refuse "a malformed digest" --manifest "${work}/bad-digest.json"
jq '.images |= .[:2]' "${work}/good.json" > "${work}/missing.json"
refuse "a manifest without every Cloud Run service" --manifest "${work}/missing.json"
jq '.images[1].service = "accounts"' "${work}/good.json" > "${work}/duplicate.json"
refuse "a duplicated service" --manifest "${work}/duplicate.json"
jq '.images[0].image = "asia-east1-docker.pkg.dev/open-platform-uat/other/accounts"' "${work}/good.json" > "${work}/foreign.json"
refuse "an image outside the UAT serverless registry" --manifest "${work}/foreign.json"
jq '.environment = "prod"' "${work}/good.json" > "${work}/prod-env.json"
refuse "a non-UAT manifest" --manifest "${work}/prod-env.json"

# --- PROD dispatch ------------------------------------------------------------
mkdir -p "${work}/bin"
cat > "${work}/bin/gh" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${GH_LOG}"
case "$1 $2" in
  "api "*)
    if [[ "$2" == */git/ref/tags/* ]]; then
      # gh prints a 404 body to stdout, not a SHA, when the tag is missing.
      if [[ "${FAKE_TAG_MODE:-present}" == missing ]]; then
        echo '{"message":"Not Found","documentation_url":"https://docs.github.com/rest/git/refs#get-a-reference","status":"404"}'
        exit 1
      fi
      echo "${FAKE_TAG_SHA}"
    elif [[ "$*" == *"--jq"* ]]; then printf 'completed\tsuccess\n'
    else cat "${FAKE_UAT_RUN}"
    fi ;;
  "workflow run") echo "https://github.com/ai-workspace-infra/platform-ops-toolkit/actions/runs/9001" ;;
  "run view") printf '{"headBranch":"v2026.10.01-r1","headSha":"%s"}\n' "${FAKE_TAG_SHA}" ;;
  "run download")
    [[ "${FAKE_ARTIFACT_MODE:-present}" == present ]] || exit 1
    destination=''
    while (($#)); do
      if [[ "$1" == --dir ]]; then destination="$2"; break; fi
      shift
    done
    [[ -n "${destination}" ]] || exit 1
    mkdir -p "${destination}"
    cp "${FAKE_ACCEPTED_ARTIFACT}" "${destination}/uat-artifact-manifest.json"
    ;;
esac
FAKE
chmod +x "${work}/bin/gh"

dispatch() {
  local log="$1"; shift
  : > "${log}"
  env PATH="${work}/bin:${PATH}" GH_LOG="${log}" GH_TOKEN=test RUN_STATUS_TOKEN=test \
    FAKE_ACCEPTED_ARTIFACT="${work}/good.json" FAKE_TAG_SHA="$(printf 'f%.0s' {1..40})" \
    RELEASE_TAG=v2026.10.01-r1 UAT_SNAPSHOT_TAG=daily-build-2026.10.01-r1 PROD_RUN_WAIT_TIMEOUT_SECONDS=5 \
    RUN_POLL_INTERVAL_SECONDS=1 "$@" bash "${prod_dispatcher}" > "${log}.out" 2>&1
}

dispatch "${work}/none.log" PROMOTION_MANIFEST_FILE= FAKE_UAT_RUN="${work}/run-ok.json" \
  && fail "PROD dispatch without a UAT manifest (main→prod) must be refused"
! grep -q 'workflow run' "${work}/none.log" || fail "nothing may be dispatched without a UAT manifest"

dispatch "${work}/failed.log" PROMOTION_MANIFEST_FILE="${work}/good.json" FAKE_UAT_RUN="${work}/run-failed.json" \
  && fail "PROD dispatch for a failed UAT run must be refused"
! grep -q 'workflow run' "${work}/failed.log" || fail "a failed UAT run must stop before any dispatch"

dispatch "${work}/pending.log" PROMOTION_MANIFEST_FILE="${work}/good.json" FAKE_UAT_RUN="${work}/run-pending.json" \
  && fail "PROD dispatch for a pending UAT run must be refused"
! grep -q 'workflow run' "${work}/pending.log" || fail "a pending UAT run must stop before any dispatch"

dispatch "${work}/ok.log" PROMOTION_MANIFEST_FILE="${work}/good.json" FAKE_UAT_RUN="${work}/run-ok.json" \
  || { cat "${work}/ok.log.out" >&2; fail "PROD dispatch for a successful UAT manifest must proceed"; }
serverless_call="$(grep '^workflow run serverless-orchestrator.yml' "${work}/ok.log")"

# A missing release tag must stop PROD: gh's 404 body is not a tag SHA.
mkdir -p "${work}/nosleep"
printf '#!/usr/bin/env bash\nexit 0\n' > "${work}/nosleep/sleep"
chmod +x "${work}/nosleep/sleep"
dispatch "${work}/notag.log" PATH="${work}/nosleep:${work}/bin:${PATH}" FAKE_TAG_MODE=missing \
  PROMOTION_MANIFEST_FILE="${work}/good.json" FAKE_UAT_RUN="${work}/run-ok.json" \
  && fail "PROD dispatch must refuse a release tag that does not exist"
grep -Fq 'is not visible through the GitHub refs API' "${work}/notag.log.out" \
  || fail "a missing release tag must be reported as not visible"
! grep -q '^workflow run' "${work}/notag.log" || fail "nothing may be dispatched without the release tag"
grep -Fq -- "-f promotion_manifest=${normalized}" <<<"${serverless_call}" \
  || fail "PROD Serverless must receive the verified UAT manifest"

# A real successful UAT run is not evidence for arbitrary hand-written
# digests/source metadata: compare with that run's own immutable artifact.
for field in digest source_sha image; do
  case "${field}" in
    digest) jq --arg d "${digest_b}" '.images[0].digest = $d' "${work}/good.json" > "${work}/tampered.json" ;;
    source_sha) jq '.images[0].source_sha = "dddddddddddddddddddddddddddddddddddddddd"' "${work}/good.json" > "${work}/tampered.json" ;;
    image) jq '.images[0].image = "asia-east1-docker.pkg.dev/foreign-project/serverless/accounts"' "${work}/good.json" > "${work}/tampered.json" ;;
  esac
  jq '.upgrade_acceptance.images = (.images | sort_by(.service))' "${work}/tampered.json" > "${work}/tampered-proof.json"
  mv "${work}/tampered-proof.json" "${work}/tampered.json"
  # Demonstrate that the former shape + successful-run gate alone accepts
  # this substitution, so the artifact comparison is a distinct regression.
  python3 "${verifier}" --manifest "${work}/tampered.json" --uat-run-json "${work}/run-ok.json" \
    --release-tag v2026.10.01-r1 >/dev/null || fail "tampering fixture must pass the old shape-only gate"
  dispatch "${work}/tampered-${field}.log" PROMOTION_MANIFEST_FILE="${work}/tampered.json" FAKE_UAT_RUN="${work}/run-ok.json" \
    && fail "a successful run must not authorize a substituted ${field}"
  ! grep -q 'workflow run' "${work}/tampered-${field}.log" || fail "a substituted ${field} must stop before dispatch"
done
dispatch "${work}/expired.log" PROMOTION_MANIFEST_FILE="${work}/good.json" FAKE_UAT_RUN="${work}/run-ok.json" FAKE_ARTIFACT_MODE=missing \
  && fail "a missing/expired UAT artifact must prevent promotion"
! grep -q 'workflow run' "${work}/expired.log" || fail "nothing may dispatch with missing UAT artifact proof"

# --- PROD Serverless preflight --------------------------------------------------
preflight_run() {
  env PATH="${work}/bin:${PATH}" GH_LOG="${work}/preflight.log" GH_TOKEN=test \
    FAKE_ACCEPTED_ARTIFACT="${work}/good.json" \
    GITHUB_REPOSITORY=ai-workspace-infra/platform-ops-toolkit RELEASE_TAG=v2026.10.01-r1 "$@" \
    bash "${preflight}" >/dev/null 2>&1
}
preflight_run VAULT_ENV_PATH=prod DEPLOYS_CLOUD_RUN=true PROMOTION_MANIFEST= \
  && fail "PROD Cloud Run without a manifest must not rebuild from source"
preflight_run VAULT_ENV_PATH=prod DEPLOYS_CLOUD_RUN=true PROMOTION_MANIFEST="$(cat "${work}/good.json")" FAKE_UAT_RUN="${work}/run-failed.json" \
  && fail "a hand-made PROD dispatch must re-check the UAT verdict"
preflight_run VAULT_ENV_PATH=prod DEPLOYS_CLOUD_RUN=true PROMOTION_MANIFEST="$(cat "${work}/good.json")" FAKE_UAT_RUN="${work}/run-ok.json" \
  || fail "PROD Cloud Run with a verified manifest must pass preflight"
preflight_run VAULT_ENV_PATH=prod DEPLOYS_CLOUD_RUN=true PROMOTION_MANIFEST="$(cat "${work}/tampered.json")" FAKE_UAT_RUN="${work}/run-ok.json" \
  && fail "direct Serverless dispatch must reject substituted artifact provenance"
preflight_run VAULT_ENV_PATH=prod DEPLOYS_CLOUD_RUN=true PROMOTION_MANIFEST="$(cat "${work}/good.json")" FAKE_UAT_RUN="${work}/run-ok.json" FAKE_ARTIFACT_MODE=missing \
  && fail "direct Serverless dispatch must require the UAT run artifact"
preflight_run VAULT_ENV_PATH=uat DEPLOYS_CLOUD_RUN=true PROMOTION_MANIFEST="$(cat "${work}/good.json")" \
  && fail "UAT must refuse a promotion manifest"
preflight_run VAULT_ENV_PATH=uat DEPLOYS_CLOUD_RUN=true PROMOTION_MANIFEST= || fail "UAT builds normally without a manifest"

# --- promote by digest and verify the serving revision -------------------------
cat > "${work}/bin/gcloud" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${GCLOUD_LOG}"
case "$*" in
  "artifacts docker images describe"*)
    [[ -f "${FAKE_TARGET_DIGEST}" ]] && cat "${FAKE_TARGET_DIGEST}" ;;
  "container images add-tag"*)
    printf '%s\n' "${FAKE_COPIED_DIGEST}" > "${FAKE_TARGET_DIGEST}" ;;
  "run services describe"*)
    echo '{"status":{"latestReadyRevisionName":"prod-accounts-00002","traffic":[{"revisionName":"prod-accounts-00002","percent":100}]}}' ;;
  "run revisions describe"*)
    printf 'asia-east1-docker.pkg.dev/open-platform-prod/serverless/accounts@%s\n' "${FAKE_SERVING_DIGEST}" ;;
esac
FAKE
chmod +x "${work}/bin/gcloud"

promote_run() {
  env PATH="${work}/bin:${PATH}" GCLOUD_LOG="${work}/gcloud.log" FAKE_TARGET_DIGEST="${work}/target-digest" \
    PROMOTION_MANIFEST="${normalized}" SERVICE=accounts IMAGE_TAG=v2026.10.01-r1 \
    TARGET_IMAGE=asia-east1-docker.pkg.dev/open-platform-prod/serverless/accounts "$@" \
    bash "${promote}" >/dev/null 2>&1
}
rm -f "${work}/target-digest"; : > "${work}/gcloud.log"
promote_run FAKE_COPIED_DIGEST="${digest_a}" || fail "copying the UAT digest must succeed"
grep -Fq "container images add-tag $(image accounts)@${digest_a} asia-east1-docker.pkg.dev/open-platform-prod/serverless/accounts:v2026.10.01-r1" "${work}/gcloud.log" \
  || fail "PROD must copy the UAT image by digest"
! grep -q 'build' "${work}/gcloud.log" || fail "PROD must never build"

rm -f "${work}/target-digest"
promote_run FAKE_COPIED_DIGEST="${digest_b}" && fail "a copy that resolves to another digest must be refused"

printf '%s\n' "${digest_b}" > "${work}/target-digest"; : > "${work}/gcloud.log"
promote_run FAKE_COPIED_DIGEST="${digest_a}" && fail "an existing release tag with another digest must not be overwritten"
! grep -q 'add-tag' "${work}/gcloud.log" || fail "an occupied release tag must not be re-pointed"

revision_run() {
  env PATH="${work}/bin:${PATH}" GCLOUD_LOG="${work}/gcloud.log" GCP_PROJECT_ID=open-platform-prod GCP_REGION=asia-east1 \
    CLOUD_RUN_SERVICE_NAME=prod-accounts EXPECTED_DIGEST="${digest_a}" "$@" bash "${verify_revision}" >/dev/null 2>&1
}
revision_run FAKE_SERVING_DIGEST="${digest_a}" || fail "a revision serving the UAT digest must verify"
revision_run FAKE_SERVING_DIGEST="${digest_b}" && fail "a revision serving another digest must be refused"

# Buildx pushes an image index; Cloud Run serves its linux/amd64 child.
digest_child="sha256:$(printf 'd%.0s' {1..64})"
digest_attest="sha256:$(printf 'e%.0s' {1..64})"
cat > "${work}/bin/docker" <<FAKE
#!/usr/bin/env bash
[[ "\$*" == "buildx imagetools inspect --raw asia-east1-docker.pkg.dev/open-platform-prod/serverless/accounts@${digest_a}" ]] || exit 1
cat "\${FAKE_INDEX}"
FAKE
chmod +x "${work}/bin/docker"
jq -n --arg c "${digest_child}" --arg a "${digest_attest}" '{mediaType:"application/vnd.oci.image.index.v1+json",manifests:[
  {digest:$c, platform:{os:"linux", architecture:"amd64"}},
  {digest:$a, platform:{os:"unknown", architecture:"unknown"}}]}' > "${work}/index.json"
index_run() { revision_run IMAGE=asia-east1-docker.pkg.dev/open-platform-prod/serverless/accounts FAKE_INDEX="${work}/index.json" "$@"; }
index_run FAKE_SERVING_DIGEST="${digest_child}" || fail "the linux/amd64 image of the accepted index must verify"
index_run FAKE_SERVING_DIGEST="${digest_a}" || fail "the accepted index digest itself must verify"
index_run FAKE_SERVING_DIGEST="${digest_attest}" && fail "the attestation manifest is not a servable image"
index_run FAKE_SERVING_DIGEST="${digest_b}" && fail "an unrelated digest must still be refused"
jq '.manifests += [{digest:"sha256:'"$(printf 'f%.0s' {1..64})"'", platform:{os:"linux", architecture:"amd64"}}]' "${work}/index.json" > "${work}/ambiguous.json"
revision_run IMAGE=asia-east1-docker.pkg.dev/open-platform-prod/serverless/accounts FAKE_INDEX="${work}/ambiguous.json" \
  FAKE_SERVING_DIGEST="${digest_child}" && fail "an index with several linux/amd64 images is ambiguous"

# --- workflow wiring --------------------------------------------------------------
python3 - "${repo_root}/.github/workflows" <<'PY'
import sys
from pathlib import Path
import yaml

root = Path(sys.argv[1])
load = lambda name: yaml.safe_load((root / name).read_text(encoding="utf-8"))

serverless = load("serverless-orchestrator.yml")
assert "promotion_manifest" in serverless[True]["workflow_dispatch"]["inputs"]
assert serverless["permissions"].get("actions") == "read"
preflight = [s.get("run", "") for s in serverless["jobs"]["preflight"]["steps"]]
assert "./.github/scripts/serverless/validate_promotion_manifest.sh" in preflight
steps = serverless["jobs"]["cloud_run"]["steps"]
names = [s.get("name") for s in steps]
by_name = {s.get("name"): s for s in steps}
build = by_name["Build and publish target Cloud Run image"]
assert build.get("id") == "build" and build.get("if") == "${{ inputs.vault_env_path != 'prod' }}", "PROD must not build"
promote = by_name["Promote the UAT-accepted image by digest"]
assert promote.get("if") == "${{ inputs.vault_env_path == 'prod' }}" and promote.get("id") == "promoted"
order = [names.index(n) for n in (
    "Build and publish target Cloud Run image", "Promote the UAT-accepted image by digest",
    "Wait for service image in Artifact Registry", "Deploy Cloud Run service",
    "Verify the serving revision runs the expected digest", "Record the UAT image digest",
    "Upload the UAT image digest record")]
assert order == sorted(order), "build/promote → wait → deploy → verify digest → record"
assert by_name["Verify the serving revision runs the expected digest"]["env"]["IMAGE"].endswith("/serverless/${{ matrix.service }}")
for name in ("Record the UAT image digest", "Upload the UAT image digest record"):
    assert by_name[name].get("if") == "${{ inputs.vault_env_path != 'prod' }}"
manifest_job = serverless["jobs"]["artifact_manifest"]
assert manifest_job["needs"] == ["cloud_run"]
assert any(s.get("with", {}).get("name") == "serverless-artifact-manifest" for s in manifest_job["steps"])

hybrid = load("hybrid-orchestrator.yml")
hsteps = hybrid["jobs"]["resource_orchestration"]["steps"]
hnames = [s.get("name") for s in hsteps]
assert hnames.index("Upload the UAT artifact manifest") == hnames.index("Dispatch and wait for resource lanes") + 1
assert hsteps[hnames.index("Upload the UAT artifact manifest")]["with"]["name"] == "uat-artifact-manifest"

daily = load("daily-main-snapshot.yaml")
summary = {s.get("name"): s for s in daily["jobs"]["snapshot-summary"]["steps"]}
assert "dispatch-uat-combined.sh" in summary["Dispatch UAT Hybrid Orchestrator"]["run"]
# Daily was restricted to SIT/UAT in #1235. Keep the executable PROD
# preflight tests above without restoring removed production jobs.
assert "prod" not in daily[True]["workflow_dispatch"]["inputs"]["deploy_env"]["options"]
assert "promote-prod" not in daily["jobs"]
PY

echo "prod_same_digest_promotion_test: PASS"
