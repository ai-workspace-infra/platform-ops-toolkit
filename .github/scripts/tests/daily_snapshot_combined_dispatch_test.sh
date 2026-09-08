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
if [[ "$1" == "api" ]]; then
  if [[ " $* " == *"/contents/vpn-overlay/uat/xconnect-lab.json"* ]]; then
    printf '%s\n' '{"spec":{"artifacts":{"one":{"release_tag":"v0.1.7"},"gateway":{"release_tag":"v0.1.3"},"xray":{"release_tag":"v26.3.27"}}}}'
  elif [[ " $* " == *"/commits/"* ]]; then
    printf '%s\n' '0123456789012345678901234567890123456789'
  fi
  exit 0
fi
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
SKIP_STRIPE_CATALOG=true \
UAT_SERVERLESS_WAIT_TIMEOUT_SECONDS=30 \
UAT_SERVERLESS_WAIT_INTERVAL_SECONDS=1 \
bash "${dispatcher}"

serverless_line="$(grep -n '^workflow run serverless-orchestrator.yml ' "${workdir}/gh.log" | cut -d: -f1)"
watch_line="$(grep -n '^run watch 1001 ' "${workdir}/gh.log" | cut -d: -f1)"
selfhost_line="$(grep -n '^workflow run selfhost-orchestrator.yml ' "${workdir}/gh.log" | cut -d: -f1)"
lab_line="$(grep -n '^workflow run xconnect-zero-cloud.yaml ' "${workdir}/gh.log" | cut -d: -f1)"

[[ -n "${serverless_line}" && -n "${watch_line}" && -n "${lab_line}" && -n "${selfhost_line}" ]] || {
  echo "combined dispatcher did not issue serverless, XConnect Lab, and selfhost runs with the serverless wait" >&2
  exit 1
}
(( serverless_line < watch_line && watch_line < lab_line && lab_line < selfhost_line )) || {
  echo "XConnect Lab and selfhost Agent Proxy dispatch must follow successful serverless completion" >&2
  exit 1
}

grep -Fq -- '-f operation=deploy' "${workdir}/gh.log"
grep -Fq -- '-f target_domains=web-saas' "${workdir}/gh.log"
grep -Fq -- '-f vault_env_path=uat' "${workdir}/gh.log"
grep -Fq -- '-f tag_ref=uat-daily-build-2026.08.21-r5' "${workdir}/gh.log"
grep -Fq -- '-f dns_mode=uat-records' "${workdir}/gh.log"
grep -Fq -- '-f skip_stripe_catalog=true' "${workdir}/gh.log"
grep -Fq -- '-f operation=deploy' "${workdir}/gh.log"
grep -Fq -- '-f target_domains=agent-proxy' "${workdir}/gh.log"
grep -Fq -- '-f cloud_provider=aws-cloud' "${workdir}/gh.log"
grep -Fq -- '-f agent_proxy_plan=2C2G' "${workdir}/gh.log"
grep -Fq -- '-f deploy_tag=uat-daily-build-2026.08.21-r5' "${workdir}/gh.log"
grep -Fq -- '-f agent_controller_url=https://accounts-serverless-uat.onwalk.net' "${workdir}/gh.log"
grep -Fq -- '-f iac_ref=0123456789012345678901234567890123456789' "${workdir}/gh.log"
grep -Fq -- '-f gitops_ref=0123456789012345678901234567890123456789' "${workdir}/gh.log"
grep -Fq -- 'contents/vpn-overlay/uat/xconnect-lab.json?ref=0123456789012345678901234567890123456789' "${workdir}/gh.log"
grep -Fq -- '-f cli_release_tag=v0.1.7' "${workdir}/gh.log"
grep -Fq -- '-f gateway_release_tag=v0.1.3' "${workdir}/gh.log"
grep -Fq -- '-f xray_release_tag=v26.3.27' "${workdir}/gh.log"

GH_LOG="${workdir}/gh-override.log" \
PATH="${workdir}:${PATH}" \
GH_TOKEN=test-token \
SNAPSHOT_TAG=uat-daily-build-2026.08.21-r5 \
SKIP_STRIPE_CATALOG=true \
XCONNECT_ONE_RELEASE_TAG=v0.1.9 \
XCONNECT_GATEWAY_RELEASE_TAG=v0.1.4 \
UAT_SERVERLESS_WAIT_TIMEOUT_SECONDS=30 \
UAT_SERVERLESS_WAIT_INTERVAL_SECONDS=1 \
bash "${dispatcher}"

grep -Fq -- '-f cli_release_tag=v0.1.9' "${workdir}/gh-override.log"
grep -Fq -- '-f gateway_release_tag=v0.1.4' "${workdir}/gh-override.log"
echo "daily_snapshot_combined_dispatch_test: PASS"
