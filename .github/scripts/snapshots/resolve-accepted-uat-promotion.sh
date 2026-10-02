#!/usr/bin/env bash
# deploy_env=prod: promote what an earlier Daily run accepted in UAT.
#
# PROD never rebuilds from source (plan §7, GAP-16, TC-10); it promotes the
# exact images a successful UAT Hybrid run accepted. Running the whole UAT
# again only to retry a failed promotion costs about an hour, and re-running
# the failed promote-prod job reuses the old workflow commit. This read-only
# gate lets a fresh Daily run on current main pick up an earlier acceptance:
#
#   1. the run is this repository's Daily workflow on protected main;
#   2. in its latest attempt, the UAT job dispatched the UAT Hybrid
#      successfully and uploaded the verified promotion manifest (the run as a
#      whole may have failed later, e.g. in promote-prod);
#   3. that manifest is downloaded from the run itself, never supplied by the
#      caller, and verify-accepted-promotion-manifest.sh re-checks it against
#      the UAT Hybrid run's own artifact and success.
#
# Everything happens before the production approval and before any
# credential, tag or deployment. The caller's optional snapshot_source_ref and
# snapshot_tag must agree with what the run accepted.
set -euo pipefail

run_id="${UAT_DAILY_RUN_ID:-}"
repository="${RUN_REPOSITORY:?RUN_REPOSITORY is required}"
: "${GH_TOKEN:?GH_TOKEN is required}"
manifest_output="${MANIFEST_OUTPUT:?MANIFEST_OUTPUT is required}"
output_file="${GITHUB_OUTPUT:-/dev/stdout}"
summary_file="${GITHUB_STEP_SUMMARY:-/dev/null}"
scripts="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
daily_workflow_path=".github/workflows/daily-main-snapshot.yaml"
uat_job_name="Summarize daily snapshot status"
uat_dispatch_step="Dispatch UAT Hybrid Orchestrator"
manifest_upload_step="Upload the verified UAT promotion manifest"

refuse() {
  echo "::error::Refusing PROD promotion: $*" >&2
  exit 1
}

[[ "${run_id}" =~ ^[1-9][0-9]*$ ]] || {
  echo "::error::deploy_env=prod promotes an accepted UAT run and never rebuilds from source: set uat_daily_run_id to the Daily run whose UAT Hybrid succeeded." >&2
  exit 2
}

# These inputs only shape a UAT run. Silently dropping them would let a caller
# believe PROD ran a migration or a partial release (GAP-15).
for uat_only in \
  "repositories=${SNAPSHOT_REPOS:-}" \
  "enable_migration=${ENABLE_MIGRATION:-false}" \
  "apply_accounts_schema_migration=${APPLY_ACCOUNTS_SCHEMA_MIGRATION:-false}" \
  "adopt_accounts_baseline=${ADOPT_ACCOUNTS_BASELINE:-false}" \
  "xconnect_one_release_tag=${XCONNECT_ONE_RELEASE_TAG:-}" \
  "xconnect_gateway_release_tag=${XCONNECT_GATEWAY_RELEASE_TAG:-}"; do
  case "${uat_only#*=}" in
    '' | false) ;;
    *)
      echo "::error::${uat_only%%=*} applies to UAT runs only; a PROD promotion deploys the accepted UAT artifacts unchanged." >&2
      exit 2
      ;;
  esac
done

work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT

gh api "repos/${repository}/actions/runs/${run_id}" > "${work}/run.json" \
  || refuse "cannot read Daily run ${run_id} in ${repository}."
jq -e --arg path "${daily_workflow_path}" --arg repository "${repository}" '
  (.path | split("@")[0]) == $path
  and .repository.full_name == $repository
  and .head_branch == "main"
  and (.event == "schedule" or .event == "workflow_dispatch")
' "${work}/run.json" >/dev/null \
  || refuse "run ${run_id} is not a Daily Main Snapshot run of ${repository} on main."
[[ "$(jq -r '.status' "${work}/run.json")" == completed ]] \
  || refuse "Daily run ${run_id} is still $(jq -r '.status' "${work}/run.json"); promote only a finished run."

gh api "repos/${repository}/actions/runs/${run_id}/jobs?filter=latest&per_page=100" > "${work}/jobs.json" \
  || refuse "cannot read the jobs of Daily run ${run_id}."
step_conclusion() {
  jq -r --arg job "${uat_job_name}" --arg step "$1" '
    [.jobs[] | select(.name == $job)] as $jobs
    | if ($jobs | length) != 1 then "missing-job"
      elif $jobs[0].conclusion != "success" then "job-" + ($jobs[0].conclusion // "pending")
      else ([$jobs[0].steps[]? | select(.name == $step) | .conclusion] | if length == 1 then .[0] // "pending" else "missing" end)
      end
  ' "${work}/jobs.json"
}
for step in "${uat_dispatch_step}" "${manifest_upload_step}"; do
  conclusion="$(step_conclusion "${step}")"
  [[ "${conclusion}" == success ]] \
    || refuse "Daily run ${run_id} did not complete '${step}' successfully (${conclusion}); its UAT was not accepted."
done

GH_TOKEN="${ARTIFACT_GH_TOKEN:-${GH_TOKEN}}" gh run download "${run_id}" --repo "${repository}" \
  --name uat-promotion-manifest --dir "${work}/accepted" \
  || refuse "cannot download uat-promotion-manifest from Daily run ${run_id} (expired or missing)."
manifest="${work}/accepted/uat-promotion-manifest.json"
[[ -s "${manifest}" && ! -L "${manifest}" ]] || refuse "Daily run ${run_id} has no non-empty promotion manifest."

uat_tag="$(jq -er '.snapshot_tag | strings' "${manifest}")" || refuse "the promotion manifest names no UAT snapshot tag."
case "${uat_tag}" in
  uat-daily-build-*) release_tag="v${uat_tag#uat-daily-build-}" ;;
  daily-build-*) release_tag="v${uat_tag#daily-build-}" ;;
  *) refuse "manifest snapshot tag ${uat_tag} is not an immutable daily-build tag." ;;
esac
if [[ -n "${SNAPSHOT_SOURCE_REF:-}" && "${SNAPSHOT_SOURCE_REF}" != "${uat_tag}" ]]; then
  refuse "snapshot_source_ref ${SNAPSHOT_SOURCE_REF} is not the UAT tag ${uat_tag} that Daily run ${run_id} accepted."
fi
if [[ -n "${SNAPSHOT_TAG:-}" && "${SNAPSHOT_TAG}" != "${release_tag}" ]]; then
  refuse "snapshot_tag ${SNAPSHOT_TAG} differs from ${release_tag}, the release tag promoted from ${uat_tag}."
fi

# The same provenance gate the PROD dispatch runs again: the UAT Hybrid run
# named by the manifest succeeded and accepted exactly these digests.
normalized="$(RUN_REPOSITORY="${repository}" bash "${scripts}/verify-accepted-promotion-manifest.sh" \
  "${manifest}" "${release_tag}" "${uat_tag}")"

install -m 0644 "${manifest}" "${manifest_output}"
uat_hybrid_run_id="$(jq -r '.uat_run_id' <<<"${normalized}")"
uat_control_plane_sha="$(jq -r '.head_sha' "${work}/run.json")"
{
  echo "uat_snapshot_tag=${uat_tag}"
  echo "release_tag=${release_tag}"
  echo "uat_hybrid_run_id=${uat_hybrid_run_id}"
} >> "${output_file}"

server="${GITHUB_SERVER_URL:-https://github.com}"
{
  echo "### Accepted UAT run for PROD promotion"
  echo
  echo "| Field | Value |"
  echo "| --- | --- |"
  echo "| Daily run | [${run_id}](${server}/${repository}/actions/runs/${run_id}) |"
  echo "| UAT Hybrid run | [${uat_hybrid_run_id}](${server}/${repository}/actions/runs/${uat_hybrid_run_id}) |"
  echo "| UAT snapshot tag | \`${uat_tag}\` |"
  echo "| PROD release tag | \`${release_tag}\` |"
  echo "| UAT control-plane SHA | \`${uat_control_plane_sha}\` |"
  echo "| Promotion control-plane SHA | \`${GITHUB_SHA:-unknown}\` |"
  echo
  echo "| Service | Digest | Source SHA |"
  echo "| --- | --- | --- |"
  jq -r '.images[] | "| \(.service) | `\(.digest)` | `\(.source_sha)` |"' <<<"${normalized}"
} >> "${summary_file}"
echo "Daily run ${run_id} accepted ${uat_tag} in UAT Hybrid run ${uat_hybrid_run_id}; promoting it as ${release_tag}."
