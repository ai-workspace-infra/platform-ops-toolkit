#!/usr/bin/env bash
# deploy_env=prod promotes what an earlier Daily run accepted in UAT (plan §7,
# TC-10). resolve-accepted-uat-promotion.sh must accept only a finished Daily
# run on main whose UAT job dispatched the UAT Hybrid and uploaded the verified
# manifest, even when the run failed later in promote-prod, and must refuse
# everything else before any credential, tag or deployment.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
resolver="${repo_root}/.github/scripts/snapshots/resolve-accepted-uat-promotion.sh"
workflow="${repo_root}/.github/workflows/daily-main-snapshot.yaml"
repository="ai-workspace-infra/platform-ops-toolkit"
work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

uat_tag="daily-build-2026.10.01-r7"
release_tag="v2026.10.01-r7"
daily_run=5151
hybrid_run=4242
digest_a="sha256:$(printf 'a%.0s' {1..64})"
digest_b="sha256:$(printf 'b%.0s' {1..64})"
sha="$(printf 'c%.0s' {1..40})"
image() { printf 'asia-east1-docker.pkg.dev/open-platform-uat/serverless/%s' "$1"; }

write_manifest() {
  jq -n --arg tag "${uat_tag}" --arg run "${hybrid_run}" --arg digest "${2:-${digest_a}}" --arg sha "${sha}" \
    --arg ia "$(image accounts)" --arg ib "$(image billing-service)" --arg ic "$(image content-service)" \
    '{schema:1, environment:"uat", snapshot_tag:$tag, uat_run_id:$run, images:[
      {service:"accounts", image:$ia, tag:$tag, digest:$digest, source_repository:"ai-workspace-services/accounts", source_sha:$sha},
      {service:"billing-service", image:$ib, tag:$tag, digest:$digest, source_repository:"ai-workspace-services/billing-service", source_sha:$sha},
      {service:"content-service", image:$ic, tag:$tag, digest:$digest, source_repository:"ai-workspace-services/content-service", source_sha:$sha}]}' > "$1"
}
# A Daily run record. The run as a whole may have failed (in promote-prod).
write_daily_run() {
  jq -n --argjson id "${daily_run}" --arg repo "${repository}" --arg path "${2:-.github/workflows/daily-main-snapshot.yaml}" \
    --arg branch "${3:-main}" --arg status "${4:-completed}" --arg event "${5:-workflow_dispatch}" \
    '{id:$id, path:($path + "@refs/heads/main"), repository:{full_name:$repo}, head_branch:$branch,
      head_sha:"dddddddddddddddddddddddddddddddddddddddd", event:$event, status:$status, conclusion:"failure"}' > "$1"
}
write_jobs() {
  jq -n --arg job "${2:-success}" --arg dispatch "${3:-success}" --arg upload "${4:-success}" '
    def step($name; $conclusion): if $conclusion == "absent" then empty else {name:$name, conclusion:$conclusion} end;
    {jobs:[
      {name:"Tag and build main snapshot (ai-workspace-services)", conclusion:"success", steps:[]},
      {name:"Summarize daily snapshot status", conclusion:$job, steps:[
        step("Check Shared platform readiness (read-only)"; "success"),
        step("Dispatch UAT Hybrid Orchestrator"; $dispatch),
        step("Upload the verified UAT promotion manifest"; $upload)]},
      {name:"Promote verified UAT snapshot to PROD", conclusion:"failure", steps:[]}]}' > "$1"
}
write_hybrid_run() {
  jq -n --argjson id "${hybrid_run}" --arg conclusion "${2:-success}" \
    '{id:$id, path:".github/workflows/hybrid-orchestrator.yml@refs/heads/main", status:"completed", conclusion:$conclusion}' > "$1"
}

write_manifest "${work}/promotion.json"
write_manifest "${work}/accepted.json"
write_manifest "${work}/other-digest.json" "${digest_b}"
write_daily_run "${work}/daily.json"
write_jobs "${work}/jobs.json"
write_hybrid_run "${work}/hybrid.json"

mkdir -p "${work}/bin"
cat > "${work}/bin/gh" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${GH_LOG}"
runs="repos/${FAKE_REPOSITORY}/actions/runs"
case "$1" in
  api)
    case "$2" in
      "${runs}/${FAKE_DAILY_RUN_ID}") cat "${FAKE_DAILY_RUN}" ;;
      "${runs}/${FAKE_DAILY_RUN_ID}/jobs?filter=latest&per_page=100") cat "${FAKE_JOBS}" ;;
      "${runs}/${FAKE_HYBRID_RUN_ID}") cat "${FAKE_HYBRID_RUN}" ;;
      *) echo '{"message":"Not Found","status":"404"}'; echo "gh: Not Found (HTTP 404)" >&2; exit 1 ;;
    esac ;;
  run)
    [[ "$2" == download ]] || exit 1
    run_id="$3"; name=''; destination=''
    shift 3
    while (($#)); do
      case "$1" in --name) name="$2"; shift 2 ;; --dir) destination="$2"; shift 2 ;; *) shift ;; esac
    done
    case "${run_id}:${name}" in
      "${FAKE_DAILY_RUN_ID}:uat-promotion-manifest") source="${FAKE_PROMOTION_MANIFEST}" ;;
      "${FAKE_HYBRID_RUN_ID}:uat-artifact-manifest") source="${FAKE_ACCEPTED_MANIFEST}" ;;
      *) echo "no artifact ${name} in run ${run_id}" >&2; exit 1 ;;
    esac
    [[ -f "${source}" ]] || { echo "artifact expired" >&2; exit 1; }
    mkdir -p "${destination}"
    cp "${source}" "${destination}/${name}.json" ;;
  *) echo "unexpected gh call: $*" >&2; exit 1 ;;
esac
FAKE
chmod +x "${work}/bin/gh"

# resolve [VAR=value ...]: run the resolver against the fixtures above.
resolve() {
  : > "${work}/gh.log" "${work}/output" "${work}/summary"
  rm -f "${work}/out-manifest.json"
  env PATH="${work}/bin:${PATH}" GH_LOG="${work}/gh.log" GH_TOKEN=test RUN_REPOSITORY="${repository}" \
    FAKE_REPOSITORY="${repository}" FAKE_DAILY_RUN_ID="${daily_run}" FAKE_HYBRID_RUN_ID="${hybrid_run}" \
    FAKE_DAILY_RUN="${work}/daily.json" FAKE_JOBS="${work}/jobs.json" FAKE_HYBRID_RUN="${work}/hybrid.json" \
    FAKE_PROMOTION_MANIFEST="${work}/promotion.json" FAKE_ACCEPTED_MANIFEST="${work}/accepted.json" \
    UAT_DAILY_RUN_ID="${daily_run}" MANIFEST_OUTPUT="${work}/out-manifest.json" \
    GITHUB_OUTPUT="${work}/output" GITHUB_STEP_SUMMARY="${work}/summary" GITHUB_SHA="$(printf 'e%.0s' {1..40})" \
    "$@" bash "${resolver}" > "${work}/resolve.out" 2>&1
}
refused() {
  local why="$1" message="$2"; shift 2
  resolve "$@" && { cat "${work}/resolve.out" >&2; fail "${why} must be refused"; }
  grep -Fq -- "${message}" "${work}/resolve.out" || { cat "${work}/resolve.out" >&2; fail "${why}: expected '${message}'"; }
  [[ ! -e "${work}/out-manifest.json" ]] || fail "${why}: no manifest may be handed to promote-prod"
}

# --- accepted: a Daily run whose UAT succeeded and whose promotion failed ------
resolve || { cat "${work}/resolve.out" >&2; fail "an accepted UAT run must be promoted"; }
grep -Fxq "uat_snapshot_tag=${uat_tag}" "${work}/output" || fail "uat_snapshot_tag output missing"
grep -Fxq "release_tag=${release_tag}" "${work}/output" || fail "release_tag output missing"
grep -Fxq "uat_hybrid_run_id=${hybrid_run}" "${work}/output" || fail "uat_hybrid_run_id output missing"
cmp -s "${work}/promotion.json" "${work}/out-manifest.json" || fail "the Daily run's own manifest must be handed on unchanged"
grep -Fq "| accounts | \`${digest_a}\` | \`${sha}\` |" "${work}/summary" || fail "the summary must list the promoted digests"
grep -Fq "actions/runs/${daily_run}" "${work}/summary" || fail "the summary must link the accepted Daily run"
grep -Fq "run download ${hybrid_run} --repo ${repository} --name uat-artifact-manifest" "${work}/gh.log" \
  || fail "the manifest must be re-checked against the UAT Hybrid run's own artifact"

# Matching optional confirmations are accepted.
resolve SNAPSHOT_SOURCE_REF="${uat_tag}" SNAPSHOT_TAG="${release_tag}" \
  || { cat "${work}/resolve.out" >&2; fail "matching snapshot_source_ref/snapshot_tag must be accepted"; }
write_daily_run "${work}/daily.json" .github/workflows/daily-main-snapshot.yaml main completed schedule
resolve || { cat "${work}/resolve.out" >&2; fail "a scheduled Daily run's UAT acceptance must be promotable"; }
write_daily_run "${work}/daily.json"

# --- refused before any GitHub call --------------------------------------------
refused "a PROD run without an accepted UAT run" "never rebuilds from source" UAT_DAILY_RUN_ID=
[[ ! -s "${work}/gh.log" ]] || fail "a missing run id must be refused before any API call"
refused "a malformed run id" "never rebuilds from source" UAT_DAILY_RUN_ID=main
for uat_only in SNAPSHOT_REPOS=ai-workspace-services/portal ENABLE_MIGRATION=true \
    APPLY_ACCOUNTS_SCHEMA_MIGRATION=true ADOPT_ACCOUNTS_BASELINE=true \
    XCONNECT_ONE_RELEASE_TAG=v1.2.3 XCONNECT_GATEWAY_RELEASE_TAG=v1.2.3; do
  refused "UAT-only input ${uat_only%%=*}" "applies to UAT runs only" "${uat_only}"
  [[ ! -s "${work}/gh.log" ]] || fail "${uat_only%%=*} must be refused before any API call"
done

# --- refused: the run is not an accepted Daily UAT -----------------------------
write_daily_run "${work}/daily.json" .github/workflows/hybrid-orchestrator.yml
refused "a run of another workflow" "is not a Daily Main Snapshot run"
write_daily_run "${work}/daily.json" .github/workflows/daily-main-snapshot.yaml feature/x
refused "a Daily run from a branch" "is not a Daily Main Snapshot run"
write_daily_run "${work}/daily.json" .github/workflows/daily-main-snapshot.yaml main completed push
refused "a Daily run from another event" "is not a Daily Main Snapshot run"
write_daily_run "${work}/daily.json" .github/workflows/daily-main-snapshot.yaml main in_progress
refused "an unfinished Daily run" "is still in_progress"
write_daily_run "${work}/daily.json"
refused "an unknown run" "cannot read Daily run" UAT_DAILY_RUN_ID=999

write_jobs "${work}/jobs.json" failure
refused "a failed UAT job" "(job-failure)"
write_jobs "${work}/jobs.json" success skipped skipped
refused "a UAT run whose Hybrid dispatch was skipped" "'Dispatch UAT Hybrid Orchestrator' successfully (skipped)"
write_jobs "${work}/jobs.json" success failure skipped
refused "a UAT run whose Hybrid failed" "'Dispatch UAT Hybrid Orchestrator' successfully (failure)"
write_jobs "${work}/jobs.json" success success absent
refused "a UAT run without the manifest upload" "'Upload the verified UAT promotion manifest' successfully (missing)"
write_jobs "${work}/jobs.json"
! grep -q 'run download' "${work}/gh.log" || fail "an unaccepted run must be refused before any artifact download"

refused "an expired promotion manifest" "cannot download uat-promotion-manifest" FAKE_PROMOTION_MANIFEST="${work}/expired.json"
refused "a different UAT tag" "is not the UAT tag ${uat_tag}" SNAPSHOT_SOURCE_REF=daily-build-2026.09.30
refused "a different release tag" "differs from ${release_tag}" SNAPSHOT_TAG=v2026.10.02

# --- refused: the manifest does not match what the UAT Hybrid accepted ---------
refused "a manifest whose digests UAT did not accept" "differs from the successful UAT run artifact" \
  FAKE_ACCEPTED_MANIFEST="${work}/other-digest.json"
write_hybrid_run "${work}/hybrid.json" failure
refused "a manifest whose UAT Hybrid failed" "concluded failure, not success"
write_hybrid_run "${work}/hybrid.json"

# --- workflow wiring -------------------------------------------------------------
python3 - "${workflow}" "${resolver}" <<'PY'
from pathlib import Path
import re
import sys
import yaml

document = yaml.safe_load(Path(sys.argv[1]).read_text(encoding="utf-8"))
resolver = Path(sys.argv[2]).read_text(encoding="utf-8")
jobs = document["jobs"]
inputs = document[True]["workflow_dispatch"]["inputs"]
assert "uat_daily_run_id" in inputs and len(inputs) <= 25

# PROD never tags or builds from source.
assert jobs["resolve-snapshot-tag"]["if"] == "${{ (inputs.deploy_env || 'uat') != 'prod' }}"
summary = jobs["snapshot-summary"]
assert "environment" not in summary, "the UAT job must not wait for the production approval"
assert not any("dispatch-prod-combined" in str(step.get("run", "")) for step in summary["steps"])

# The read-only gate runs before the approval and holds no deployment credential.
accepted = jobs["resolve-accepted-uat"]
assert accepted["if"] == "${{ (inputs.deploy_env || 'uat') == 'prod' }}"
assert "environment" not in accepted
assert accepted["permissions"] == {"contents": "read", "actions": "read"}
uses = [step.get("uses", "") for step in accepted["steps"]]
assert not any("vault-action" in use or "create-github-app-token" in use for use in uses)
gate = next(step for step in accepted["steps"] if step.get("id") == "accepted")
assert gate["run"] == "./.github/scripts/snapshots/resolve-accepted-uat-promotion.sh"
assert gate["env"]["GH_TOKEN"] == "${{ github.token }}"
assert gate["env"]["UAT_DAILY_RUN_ID"] == "${{ inputs.uat_daily_run_id }}"
upload = next(step for step in accepted["steps"] if "upload-artifact" in step.get("uses", ""))
assert upload["with"]["name"] == "uat-promotion-manifest" and upload["with"]["if-no-files-found"] == "error"
assert upload["with"]["path"] == gate["env"]["MANIFEST_OUTPUT"]

promote = jobs["promote-prod"]
assert "resolve-accepted-uat" in promote["needs"]
assert promote["environment"] == "production"
assert promote["concurrency"] == {"group": "daily-main-snapshot-promote-prod", "cancel-in-progress": False}
tag = "${{ (inputs.deploy_env || 'uat') == 'prod' && needs.resolve-accepted-uat.outputs.uat_snapshot_tag || needs.snapshot-summary.outputs.uat_snapshot_tag }}"
steps = {step.get("name"): step for step in promote["steps"]}
assert steps["Promote verified UAT tag to PROD release tag"]["env"]["UAT_TAG"] == tag
assert steps["Dispatch promoted PROD serverless and selfhost deployment"]["env"]["UAT_SNAPSHOT_TAG"] == tag

# The resolver reads the UAT verdict by job and step name; keep them in sync.
names = {"job": summary["name"]} | {f"step{i}": step.get("name") for i, step in enumerate(summary["steps"])}
for variable in ("uat_job_name", "uat_dispatch_step", "manifest_upload_step"):
    value = re.search(rf'^{variable}="([^"]+)"$', resolver, re.M).group(1)
    assert value in names.values(), f"{variable}={value!r} is not in the Daily UAT job"
PY

echo "prod_accepted_uat_promotion_test: PASS"
