#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
dispatcher="${repo_root}/.github/scripts/snapshots/dispatch-environment-combined.sh"
workdir="$(mktemp -d)"
trap 'rm -rf "${workdir}"' EXIT

cat >"${workdir}/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == workflow && "${2:-}" == run ]]; then
  printf '%q ' "$@" >>"${GH_LOG}"
  printf '\n' >>"${GH_LOG}"
  printf 'https://github.com/ai-workspace-infra/platform-ops-toolkit/actions/runs/123456789\n'
  exit 0
fi
if [[ "${1:-}" == api ]]; then
  printf 'completed\tsuccess\n'
  exit 0
fi
echo "unexpected gh call: $*" >&2
exit 1
EOF
chmod +x "${workdir}/gh"

run_dispatch() {
  local environment="$1"
  local workflow="$2"
  local tag="${3:-uat-daily-build-2026.10.07-r1}"
  local output="${workdir}/${environment}.output"
  : >"${output}"
  env PATH="${workdir}:${PATH}" GH_LOG="${workdir}/${environment}.gh.log" \
    GH_TOKEN=dispatch-token RUN_STATUS_TOKEN=status-token \
    GITHUB_OUTPUT="${output}" SNAPSHOT_TAG="${tag}" \
    DEPLOY_ENV="${environment}" DISPATCH_WORKFLOW="${workflow}" \
    DISPATCH_OPERATION=deploy DISPATCH_TARGET_DOMAINS=all \
    TARGET_DOMAIN_BASE="${environment}.onwalk.net" \
    DISPATCH_WAIT_INTERVAL_SECONDS=1 DISPATCH_WAIT_TIMEOUT_SECONDS=1 \
    bash "${dispatcher}"
  grep -Fqx 'run_url=https://github.com/ai-workspace-infra/platform-ops-toolkit/actions/runs/123456789' "${output}"
}

run_dispatch sit serverless-orchestrator.yml
grep -Fq -- '-f vault_env_path=sit' "${workdir}/sit.gh.log"
grep -Fq -- '-f tag_ref=uat-daily-build-2026.10.07-r1' "${workdir}/sit.gh.log"
if grep -Fq 'vault_env_path=uat' "${workdir}/sit.gh.log"; then
  echo 'SIT dispatch unexpectedly used UAT.' >&2
  exit 1
fi

run_dispatch uat hybrid-orchestrator.yml
grep -Fq -- '-f vault_env_path=uat' "${workdir}/uat.gh.log"
grep -Fq -- '-f deploy_tag=uat-daily-build-2026.10.07-r1' "${workdir}/uat.gh.log"
grep -Fq -- '-f target_domain_base=uat.onwalk.net' "${workdir}/uat.gh.log"

run_dispatch prod selfhost-orchestrator.yml v2026.10.07-r1
grep -Fq -- '-f vault_env_path=prod' "${workdir}/prod.gh.log"
grep -Fq -- '-f deploy_tag=v2026.10.07-r1' "${workdir}/prod.gh.log"
grep -Fq -- '-f source_ref=v2026.10.07-r1' "${workdir}/prod.gh.log"
grep -Fq -- '-f target_domain_base=svc.plus' "${workdir}/prod.gh.log"
if grep -Fq -- '-f dns_mode=prod-cutover' "${workdir}/prod.gh.log"; then
  echo 'PROD Daily dispatch unexpectedly requested DNS cutover.' >&2
  exit 1
fi

echo "daily_snapshot_environment_dispatch_test: PASS"
