#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
resolver="${repo_root}/.github/scripts/snapshots/resolve-daily-snapshot-tag.sh"
dispatcher="${repo_root}/.github/scripts/snapshots/dispatch-uat-serverless.sh"
workdir="$(mktemp -d)"
trap 'rm -rf "${workdir}"' EXIT

mkdir -p "${workdir}/status"
printf '%s\n' '{"repository":"ai-workspace-services/accounts","tag":"uat-daily-build-2026.08.21-r2"}' > "${workdir}/status/services.jsonl"
printf '%s\n' '{"repository":"ai-workspace-services/portal","tag":"uat-daily-build-2026.08.21-r2"}' > "${workdir}/status/portal.jsonl"

GITHUB_OUTPUT="${workdir}/output" SNAPSHOT_STATUS_DIRECTORY="${workdir}/status" \
  bash "${resolver}"
grep -Fqx 'snapshot_tag=uat-daily-build-2026.08.21-r2' "${workdir}/output"

cat > "${workdir}/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%q ' "$@" > "${GH_LOG}"
printf '%s\n' >> "${GH_LOG}"
EOF
chmod +x "${workdir}/gh"

GH_LOG="${workdir}/gh.log" PATH="${workdir}:${PATH}" GH_TOKEN=test-token \
  SNAPSHOT_TAG=uat-daily-build-2026.08.21-r2 bash "${dispatcher}"
grep -Fqx 'workflow run serverless-orchestrator.yml --repo ai-workspace-infra/platform-ops-toolkit --ref main -f operation=deploy+migrate -f vault_env_path=uat -f tag_ref=uat-daily-build-2026.08.21-r2 -f deploy_cloudflare=true -f deploy_cloud_run=true -f supabase_target_existing_strategy=accounts_merge -f supabase_target_confirm_replace=false ' "${workdir}/gh.log"

echo "daily_snapshot_uat_link_test: PASS"
