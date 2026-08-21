#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
dispatcher="${repo_root}/.github/scripts/snapshots/dispatch-uat-combined.sh"
workdir="$(mktemp -d)"
trap 'rm -rf "${workdir}"' EXIT

cat > "${workdir}/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${GH_LOG}"
if [[ "$1 $2" == "workflow run" ]]; then
  if [[ "$3" == "serverless-orchestrator.yml" ]]; then
    printf '%s\n' 'https://github.com/ai-workspace-infra/platform-ops-toolkit/actions/runs/1001'
  else
    printf '%s\n' 'https://github.com/ai-workspace-infra/platform-ops-toolkit/actions/runs/1002'
  fi
fi
EOF
chmod +x "${workdir}/gh"

GH_LOG="${workdir}/gh.log" \
PATH="${workdir}:${PATH}" \
GH_TOKEN=test-token \
SNAPSHOT_TAG=uat-daily-build-2026.08.21-r5 \
UAT_SERVERLESS_WAIT_TIMEOUT_SECONDS=30 \
UAT_SERVERLESS_WAIT_INTERVAL_SECONDS=1 \
bash "${dispatcher}"

serverless_line="$(grep -n '^workflow run serverless-orchestrator.yml ' "${workdir}/gh.log" | cut -d: -f1)"
watch_line="$(grep -n '^run watch 1001 ' "${workdir}/gh.log" | cut -d: -f1)"
selfhost_line="$(grep -n '^workflow run selfhost-orchestrator.yml ' "${workdir}/gh.log" | cut -d: -f1)"

[[ -n "${serverless_line}" && -n "${watch_line}" && -n "${selfhost_line}" ]] || {
  echo "combined dispatcher did not issue both workflow runs and the serverless wait" >&2
  exit 1
}
(( serverless_line < watch_line && watch_line < selfhost_line )) || {
  echo "selfhost Agent Proxy dispatch must follow successful serverless completion" >&2
  exit 1
}

grep -Fq -- '-f operation=deploy+migrate' "${workdir}/gh.log"
grep -Fq -- '-f target_domains=web-saas' "${workdir}/gh.log"
grep -Fq -- '-f vault_env_path=uat' "${workdir}/gh.log"
grep -Fq -- '-f tag_ref=uat-daily-build-2026.08.21-r5' "${workdir}/gh.log"
grep -Fq -- '-f dns_mode=uat-records' "${workdir}/gh.log"
grep -Fq -- '-f operation=deploy' "${workdir}/gh.log"
grep -Fq -- '-f target_domains=agent-proxy' "${workdir}/gh.log"
grep -Fq -- '-f agent_proxy_plan=1C2G' "${workdir}/gh.log"
grep -Fq -- '-f deploy_tag=uat-daily-build-2026.08.21-r5' "${workdir}/gh.log"
grep -Fq -- '-f agent_controller_url=https://accounts-serverless-uat.onwalk.net' "${workdir}/gh.log"

echo "daily_snapshot_combined_dispatch_test: PASS"
