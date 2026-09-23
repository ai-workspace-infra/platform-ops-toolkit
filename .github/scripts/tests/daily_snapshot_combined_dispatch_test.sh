#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
dispatcher="${repo_root}/.github/scripts/snapshots/dispatch-uat-combined.sh"
workdir="$(mktemp -d)"
trap 'rm -rf "${workdir}"' EXIT

assert_selfhost_skip_stripe_catalog() {
  local log_file="${1:?dispatch log is required}"
  local expected="${2:?expected flag value is required}"
  local dispatch_lines

  dispatch_lines="$(grep -n '^workflow run selfhost-orchestrator.yml ' "${log_file}" | cut -d: -f1)"
  [[ -n "${dispatch_lines}" ]] || {
    echo "no selfhost dispatches found in ${log_file}" >&2
    return 1
  }

  while IFS= read -r line_number; do
    sed -n "${line_number}p" "${log_file}" | grep -Fq -- "-f skip_stripe_catalog=${expected}" || {
      echo "selfhost dispatch on line ${line_number} did not pass skip_stripe_catalog=${expected}" >&2
      return 1
    }
  done <<<"${dispatch_lines}"
}

cat > "${workdir}/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${GH_LOG}"
if [[ "$1" == "api" ]]; then
  if [[ " $* " == *"/contents/vpn-overlay/uat/xconnect-lab.json"* ]]; then
    printf '%s\n' '{"spec":{"artifacts":{"one":{"release_tag":"v0.1.7"},"gateway":{"release_tag":"v0.1.3"},"xray":{"release_tag":"v26.3.27"}}}}'
  elif [[ " $* " == *"/commits/"* || " $* " == *"/git/ref/tags/"* ]]; then
    printf '%s\n' '0123456789012345678901234567890123456789'
  fi
  exit 0
fi
if [[ "$1" == "run" && "$2" == "view" ]]; then
  printf '%s\n' "${RELEASE_TAG:-uat-daily-build-2026.08.21-r5}"
  exit 0
fi
if [[ "$1" == "run" && "$2" == "watch" ]]; then
  exit 0
fi
if [[ "$1 $2" == "workflow run" ]]; then
  if [[ "$3" == "serverless-orchestrator.yml" ]]; then
    printf '%s\n' 'https://github.com/ai-workspace-infra/platform-ops-toolkit/actions/runs/1001'
  elif [[ "$3" == "selfhost-orchestrator.yml" ]]; then
    selfhost_id_file="${GH_LOG}.selfhost-id"
    selfhost_id=2000
    if [[ -f "${selfhost_id_file}" ]]; then
      selfhost_id=$(( $(<"${selfhost_id_file}") + 1 ))
    fi
    printf '%s' "${selfhost_id}" >"${selfhost_id_file}"
    printf '%s\n' "https://github.com/ai-workspace-infra/platform-ops-toolkit/actions/runs/${selfhost_id}"
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
selfhost_lines="$(grep -n '^workflow run selfhost-orchestrator.yml ' "${workdir}/gh.log" | cut -d: -f1)"
lab_line="$(grep -n '^workflow run xconnect-zero-cloud.yaml ' "${workdir}/gh.log" | cut -d: -f1)"

[[ -n "${serverless_line}" && -n "${watch_line}" && -n "${lab_line}" && "$(wc -l <<<"${selfhost_lines}")" -eq 6 ]] || {
  echo "combined dispatcher did not issue serverless, XConnect Lab, and six isolated selfhost runs" >&2
  exit 1
}
first_selfhost_line="$(head -n1 <<<"${selfhost_lines}")"
(( serverless_line < watch_line && watch_line < lab_line && lab_line < first_selfhost_line )) || {
  echo "XConnect Lab and isolated selfhost dispatch must follow successful serverless completion" >&2
  exit 1
}

for namespace in open-platform web-saas ai-workspace agent-proxy-jp agent-proxy-us agent-proxy-sg; do
  grep -Fq -- "-f target_domains=${namespace}" "${workdir}/gh.log" || {
    echo "missing selfhost namespace dispatch: ${namespace}" >&2
    exit 1
  }
done

grep -Fq -- '-f operation=deploy' "${workdir}/gh.log"
if grep -Fq -- '-f operation=deploy+migrate' "${workdir}/gh.log"; then
  echo 'Default UAT snapshot must not sync PROD data.' >&2
  exit 1
fi
grep -Fq -- '-f accounts_source_backend=supabase' "${workdir}/gh.log"
grep -Fq -- '-f target_domains=web-saas' "${workdir}/gh.log"
grep -Fq -- '-f vault_env_path=uat' "${workdir}/gh.log"
grep -Fq -- '-f tag_ref=uat-daily-build-2026.08.21-r5' "${workdir}/gh.log"
grep -Fq -- '-f dns_mode=uat-records' "${workdir}/gh.log"
grep -Fq -- '-f skip_stripe_catalog=true' "${workdir}/gh.log"
grep -Fq -- '-f operation=deploy' "${workdir}/gh.log"
grep -Fq -- '-f cloud_provider=akamai-cloud' "${workdir}/gh.log"
grep -Fq -- '-f akamai_account=manbuzhe2026' "${workdir}/gh.log"
grep -Fq -- '-f include_external_agent_proxy=true' "${workdir}/gh.log"
grep -Fq -- '-f include_external_agent_proxy=false' "${workdir}/gh.log"
grep -Fq -- '-f dns_mode=uat-records' "${workdir}/gh.log"
grep -Fq -- '-f dns_mode=none' "${workdir}/gh.log"
grep -Fq -- '-f agent_proxy_plan=1C2G' "${workdir}/gh.log"
grep -Fq -- '-f deploy_tag=uat-daily-build-2026.08.21-r5' "${workdir}/gh.log"
grep -Fq -- '-f agent_controller_url=https://accounts-serverless-uat.onwalk.net' "${workdir}/gh.log"
assert_selfhost_skip_stripe_catalog "${workdir}/gh.log" true
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
grep -Fq -- '-f allow_release_overrides=true' "${workdir}/gh-override.log"

# Test UAT dispatch with ENABLE_MIGRATION=false (dispatches operation=deploy)
GH_LOG="${workdir}/gh-uat-no-migration.log" \
PATH="${workdir}:${PATH}" \
GH_TOKEN=test-token \
SNAPSHOT_TAG=uat-daily-build-2026.08.21-r5 \
SKIP_STRIPE_CATALOG=true \
ENABLE_MIGRATION=false \
UAT_SERVERLESS_WAIT_TIMEOUT_SECONDS=30 \
UAT_SERVERLESS_WAIT_INTERVAL_SECONDS=1 \
bash "${dispatcher}"

grep -Fq -- 'workflow run serverless-orchestrator.yml --repo ai-workspace-infra/platform-ops-toolkit --ref main -f operation=deploy' "${workdir}/gh-uat-no-migration.log"

# PROD→UAT data sync is a separate, explicit opt-in.
GH_LOG="${workdir}/gh-uat-explicit-migration.log" \
PATH="${workdir}:${PATH}" \
GH_TOKEN=test-token \
SNAPSHOT_TAG=uat-daily-build-2026.08.21-r5 \
SKIP_STRIPE_CATALOG=false \
ENABLE_MIGRATION=true \
UAT_SERVERLESS_WAIT_TIMEOUT_SECONDS=30 \
UAT_SERVERLESS_WAIT_INTERVAL_SECONDS=1 \
bash "${dispatcher}" >/dev/null
grep -Fq -- '-f operation=deploy+migrate' "${workdir}/gh-uat-explicit-migration.log"
assert_selfhost_skip_stripe_catalog "${workdir}/gh-uat-explicit-migration.log" false

# One-time baseline adoption is part of a deploy, never a PROD data sync.
GH_LOG="${workdir}/gh-uat-baseline.log" \
PATH="${workdir}:${PATH}" \
GH_TOKEN=test-token \
SNAPSHOT_TAG=uat-daily-build-2026.08.21-r5 \
ENABLE_MIGRATION=false \
ADOPT_ACCOUNTS_BASELINE=true \
UAT_SERVERLESS_WAIT_TIMEOUT_SECONDS=30 \
UAT_SERVERLESS_WAIT_INTERVAL_SECONDS=1 \
bash "${dispatcher}" >/dev/null
grep -Fq -- '-f adopt_accounts_baseline=true' "${workdir}/gh-uat-baseline.log"
grep -Fq -- '-f operation=deploy' "${workdir}/gh-uat-baseline.log"
if grep -Fq -- '-f operation=deploy+migrate' "${workdir}/gh-uat-baseline.log"; then
  echo 'UAT baseline adoption must not sync PROD data.' >&2
  exit 1
fi

# A reviewed schema migration is separate from the PROD-to-UAT data merge.
GH_LOG="${workdir}/gh-uat-schema.log" \
PATH="${workdir}:${PATH}" \
GH_TOKEN=test-token \
SNAPSHOT_TAG=uat-daily-build-2026.08.21-r5 \
ENABLE_MIGRATION=false \
APPLY_ACCOUNTS_SCHEMA_MIGRATION=true \
ACCOUNTS_SCHEMA_EXPECTED_VERSION=2026091401 \
ACCOUNTS_SCHEMA_TARGET_VERSION=2026092301 \
ACCOUNTS_SCHEMA_SHA256="$(printf 'a%.0s' {1..64})" \
UAT_SERVERLESS_WAIT_TIMEOUT_SECONDS=30 \
UAT_SERVERLESS_WAIT_INTERVAL_SECONDS=1 \
bash "${dispatcher}" >/dev/null
grep -Fq -- '-f apply_accounts_schema_migration=true' "${workdir}/gh-uat-schema.log"
grep -Fq -- '-f accounts_schema_target_version=2026092301' "${workdir}/gh-uat-schema.log"
grep -Fq -- '-f operation=deploy' "${workdir}/gh-uat-schema.log"
if grep -Fq -- '-f operation=deploy+migrate' "${workdir}/gh-uat-schema.log"; then
  echo 'Schema-only UAT dispatch must not trigger data merge.' >&2
  exit 1
fi

# Test PROD dispatch with default migration (dispatches operation=upgrade)
prod_dispatcher="${repo_root}/.github/scripts/snapshots/dispatch-prod-combined.sh"
GH_LOG="${workdir}/gh-prod-default.log" \
PATH="${workdir}:${PATH}" \
GH_TOKEN=test-token \
RELEASE_TAG=v2026.08.21 \
SKIP_STRIPE_CATALOG=true \
bash "${prod_dispatcher}"

grep -Fq -- 'workflow run serverless-orchestrator.yml --repo ai-workspace-infra/platform-ops-toolkit --ref v2026.08.21 -f operation=upgrade' "${workdir}/gh-prod-default.log"
assert_selfhost_skip_stripe_catalog "${workdir}/gh-prod-default.log" true

# Test PROD dispatch with ENABLE_MIGRATION=true (dispatches operation=deploy+migrate)
GH_LOG="${workdir}/gh-prod-migration.log" \
PATH="${workdir}:${PATH}" \
GH_TOKEN=test-token \
RELEASE_TAG=v2026.08.21 \
ENABLE_MIGRATION=true \
SKIP_STRIPE_CATALOG=true \
bash "${prod_dispatcher}"

grep -Fq -- 'workflow run serverless-orchestrator.yml --repo ai-workspace-infra/platform-ops-toolkit --ref v2026.08.21 -f operation=deploy+migrate' "${workdir}/gh-prod-migration.log"
grep -Fq -- '-f cloud_provider=aws-cloud' "${workdir}/gh-prod-migration.log"
grep -Fq -- '-f agent_proxy_plan=1C2G' "${workdir}/gh-prod-migration.log"
grep -Fq -- '-f include_external_agent_proxy=false' "${workdir}/gh-prod-migration.log"
grep -Fq -- '-f cloud_provider=akamai-cloud' "${workdir}/gh-prod-migration.log"
grep -Fq -- '-f akamai_account=manbuzhe2026' "${workdir}/gh-prod-migration.log"
grep -Fq -- '-f include_external_agent_proxy=true' "${workdir}/gh-prod-migration.log"
assert_selfhost_skip_stripe_catalog "${workdir}/gh-prod-migration.log" true
if grep -Fq 'Spot/60m' "${workdir}/gh-prod-migration.log"; then
  echo "production daily dispatch must not select an AWS Spot pool" >&2
  exit 1
fi

echo "daily_snapshot_combined_dispatch_test: PASS"
