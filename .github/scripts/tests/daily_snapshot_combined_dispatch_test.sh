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
  printf '%s\n' 'https://github.com/ai-workspace-infra/platform-ops-toolkit/actions/runs/1001'
elif [[ "$1" == api && "$*" == *"/actions/runs/1001"* ]]; then
  printf '%s\n' $'completed\tsuccess'
fi
EOF
chmod +x "${workdir}/gh"

GH_LOG="${workdir}/gh.log" \
PATH="${workdir}:${PATH}" \
GH_TOKEN=test-token \
SNAPSHOT_TAG=uat-daily-build-2026.09.28-r2 \
SKIP_STRIPE_CATALOG=true \
UAT_SELFHOST_WAIT_TIMEOUT_SECONDS=30 \
UAT_SERVERLESS_WAIT_INTERVAL_SECONDS=1 \
bash "${dispatcher}"

grep -Fq 'workflow run hybrid-orchestrator.yml' "${workdir}/gh.log"
grep -Fq 'workflow run gcp-iac-pipeline.yml' "${workdir}/gh.log"
grep -Fq -- '-f deploy_action=apply' "${workdir}/gh.log"
grep -Fq -- '-f vault_env_path=shared' "${workdir}/gh.log"
grep -Fq -- '-f gcp_account_id=open-platform-shared' "${workdir}/gh.log"
grep -Fq -- '-f gcp_resource_manifest=resources/svc.plus/shared/gcp/open-platform-shared-vault.yaml' "${workdir}/gh.log"
grep -Fq -- '-f gcp_resource_manifest=resources/svc.plus/shared/gcp/open-platform-shared-observability.yaml' "${workdir}/gh.log"
grep -Fq -- '-f gcp_resource_manifest=resources/svc.plus/shared/gcp/open-platform-shared-iam.yaml' "${workdir}/gh.log"
grep -Fq -- '-f operation=deploy' "${workdir}/gh.log"
grep -Fq -- '-f target_domains=all' "${workdir}/gh.log"
grep -Fq -- '-f deploy_tag=uat-daily-build-2026.09.28-r2' "${workdir}/gh.log"
grep -Fq -- '-f source_ref=main' "${workdir}/gh.log"
grep -Fq -- '-f routing_mode=selfhost-first' "${workdir}/gh.log"
if grep -Fq -- 'operation=destroy' "${workdir}/gh.log"; then
  echo 'Daily UAT snapshot must never dispatch destroy.' >&2
  exit 1
fi

echo "daily_snapshot_combined_dispatch_test: PASS"
