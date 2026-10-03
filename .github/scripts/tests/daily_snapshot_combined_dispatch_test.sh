#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
dispatcher="${repo_root}/.github/scripts/snapshots/dispatch-uat-combined.sh"
workdir="$(mktemp -d)"
trap 'rm -rf "${workdir}"' EXIT

grep -Fq 'selfhost_wait_timeout_seconds="${UAT_SELFHOST_WAIT_TIMEOUT_SECONDS:-10800}"' "${dispatcher}"

cat > "${workdir}/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${GH_LOG}"
printf '%s %s %s\n' "${GH_TOKEN:-none}" "$1" "$2" >> "${GH_LOG}.tokens"
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
RUN_STATUS_TOKEN=job-token \
SNAPSHOT_TAG=uat-daily-build-2026.09.28-r2 \
SKIP_STRIPE_CATALOG=true \
UAT_SELFHOST_WAIT_TIMEOUT_SECONDS=30 \
UAT_SERVERLESS_WAIT_INTERVAL_SECONDS=1 \
bash "${dispatcher}"

grep -Fq 'workflow run hybrid-orchestrator.yml' "${workdir}/gh.log"
# The App token dispatches; the job token (which outlives the 60-minute App
# token) reads the Hybrid run status until it completes.
grep -Fxq 'test-token workflow run' "${workdir}/gh.log.tokens"
grep -Fxq 'job-token api repos/ai-workspace-infra/platform-ops-toolkit/actions/runs/1001' "${workdir}/gh.log.tokens"
if grep -Fq 'test-token api' "${workdir}/gh.log.tokens"; then
  echo 'UAT Hybrid status must not be read with the dispatch App token.' >&2
  exit 1
fi
if grep -Fq 'workflow run open-platform-orchestrator.yml' "${workdir}/gh.log"; then
  echo 'Daily UAT snapshot must not mutate the independent Shared platform lifecycle.' >&2
  exit 1
fi
grep -Fq -- '-f operation=deploy' "${workdir}/gh.log"
grep -Fq -- '-f target_domains=all' "${workdir}/gh.log"
grep -Fq -- '-f deploy_tag=uat-daily-build-2026.09.28-r2' "${workdir}/gh.log"
grep -Fq -- '-f source_ref=main' "${workdir}/gh.log"
grep -Fq -- '-f routing_mode=selfhost-first' "${workdir}/gh.log"
if grep -Fq -- 'operation=destroy' "${workdir}/gh.log"; then
  echo 'Daily UAT snapshot must never dispatch destroy.' >&2
  exit 1
fi

# Requests the Hybrid Orchestrator cannot carry must fail before any dispatch
# instead of being dropped while the run still reports success.
for unsupported in ENABLE_MIGRATION=true APPLY_ACCOUNTS_SCHEMA_MIGRATION=true \
    ADOPT_ACCOUNTS_BASELINE=true XCONNECT_ONE_RELEASE_TAG=v1.2.3 \
    XCONNECT_GATEWAY_RELEASE_TAG=v1.2.3; do
  : > "${workdir}/gh.log"
  if env "${unsupported}" \
    GH_LOG="${workdir}/gh.log" PATH="${workdir}:${PATH}" GH_TOKEN=test-token \
    SNAPSHOT_TAG=uat-daily-build-2026.09.28-r2 \
    bash "${dispatcher}" >/dev/null 2>"${workdir}/err"; then
    echo "UAT dispatch must reject ${unsupported} (Hybrid cannot carry it)." >&2
    exit 1
  fi
  grep -Fiq "${unsupported%%=*}" "${workdir}/err"
  if [[ -s "${workdir}/gh.log" ]]; then
    echo "Rejected request ${unsupported} must not dispatch anything." >&2
    exit 1
  fi
done

echo "daily_snapshot_combined_dispatch_test: PASS"
