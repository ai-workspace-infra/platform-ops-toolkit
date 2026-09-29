#!/usr/bin/env bash
set -euo pipefail

# Hybrid is the only UAT multi-cloud entry point. It dispatches one child per
# matrix row and waits before moving to the next row. The provider, account,
# region, and lifecycle always come from the versioned GitOps/IAC matrix;
# operator-level cloud defaults must never overwrite a row. Terraform,
# Serverless, and existing inventory state remain owned by their workflows.
# Rows marked release_scope=shared-infrastructure are excluded from routine
# UAT deploys. Vault and Observability are shared services with their own
# lifecycle and must not be re-bootstrapped by a business release.

: "${GH_TOKEN:?GH_TOKEN is required}"
: "${GH_REPO:?GH_REPO is required}"
: "${MATRIX_FILE:?MATRIX_FILE is required}"
: "${OPERATION:?OPERATION is required}"
: "${CHILD_REF:?CHILD_REF is required}"
: "${VAULT_ENV_PATH:?VAULT_ENV_PATH is required}"
: "${TARGET_DOMAIN_BASE:?TARGET_DOMAIN_BASE is required}"
: "${OBSERVABILITY_ENDPOINT:?OBSERVABILITY_ENDPOINT is required}"
AKAMAI_ACCOUNT="${AKAMAI_ACCOUNT:-}"
AWS_ACCOUNT="${AWS_ACCOUNT:-}"
GCP_ACCOUNT="${GCP_ACCOUNT:-}"
EXISTING_ACCOUNT="${EXISTING_ACCOUNT:-}"
VULTR_ACCOUNT="${VULTR_ACCOUNT:-}"
UCLOUD_ACCOUNT="${UCLOUD_ACCOUNT:-}"

RUNNER_TYPE="${RUNNER_TYPE:-ubuntu-latest}"
SOURCE_REF="${SOURCE_REF:-main}"
DEPLOY_TAG="${DEPLOY_TAG:-}"
VAULT_ADDR="${VAULT_ADDR:-https://vault.svc.plus}"
XCONNECT_GATEWAY_REF="${XCONNECT_GATEWAY_REF:-tw-xconnect.svc.plus}"
XCONNECT_MIGRATION="${XCONNECT_MIGRATION:-false}"
DRY_RUN="${DRY_RUN:-false}"
WAIT_INTERVAL_SECONDS="${WAIT_INTERVAL_SECONDS:-15}"
REGISTRY_FILE="${REGISTRY_FILE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)/config/iac_provider_registry.json}"

[[ "${VAULT_ENV_PATH}" == uat ]] || { echo "::error::The eight-resource matrix is UAT-only; got ${VAULT_ENV_PATH}" >&2; exit 1; }
[[ "${TARGET_DOMAIN_BASE}" == onwalk.net ]] || { echo "::error::UAT hybrid matrix requires target_domain_base=onwalk.net" >&2; exit 1; }
case "${OPERATION}" in plan|apply|deploy|destroy) ;; *) echo "::error::Hybrid matrix supports plan, apply, deploy, or destroy; got ${OPERATION}" >&2; exit 1 ;; esac
if [[ "${OPERATION}" == deploy ]]; then
  [[ "${DEPLOY_TAG}" =~ ^(uat-)?daily-build-[0-9]{4}\.[0-9]{2}\.[0-9]{2}(-r[1-9][0-9]*)?$ ]] || { echo "::error::deploy requires an immutable UAT daily-build tag" >&2; exit 1; }
fi
[[ "${DRY_RUN}" == true || "${DRY_RUN}" == false ]] || { echo "::error::DRY_RUN must be true or false" >&2; exit 1; }
[[ "${XCONNECT_MIGRATION}" == true || "${XCONNECT_MIGRATION}" == false ]] || { echo "::error::XCONNECT_MIGRATION must be true or false" >&2; exit 1; }

account_for() {
  case "$1" in
    akamai) printf '%s' "${AKAMAI_ACCOUNT}" ;;
    aws) printf '%s' "${AWS_ACCOUNT}" ;;
    gcp) printf '%s' "${GCP_ACCOUNT}" ;;
    vultr) printf '%s' "${VULTR_ACCOUNT}" ;;
    ucloud) printf '%s' "${UCLOUD_ACCOUNT}" ;;
    existing) printf '%s' "${EXISTING_ACCOUNT}" ;;
    *) echo "::error::Unknown account_kind '$1'" >&2; return 1 ;;
  esac
}

account_for_row() {
  local row="$1" declared account_kind account_ref
  declared="$(jq -r '.account // empty' <<<"${row}")"
  if [[ -n "${declared}" ]]; then
    printf '%s' "${declared}"
    return 0
  fi
  account_ref="$(jq -r '.account_ref // empty' <<<"${row}")"
  if [[ -n "${account_ref}" ]]; then
    case "${account_ref}" in
      akamai_account) printf '%s' "${AKAMAI_ACCOUNT}"; return 0 ;;
      aws_account) printf '%s' "${AWS_ACCOUNT}"; return 0 ;;
      gcp_account) printf '%s' "${GCP_ACCOUNT}"; return 0 ;;
      existing_account) printf '%s' "${EXISTING_ACCOUNT}"; return 0 ;;
      vultr_account) printf '%s' "${VULTR_ACCOUNT}"; return 0 ;;
      ucloud_account) printf '%s' "${UCLOUD_ACCOUNT}"; return 0 ;;
      *) echo "::error::Unknown account_ref '${account_ref}'" >&2; return 1 ;;
    esac
  fi
  account_kind="$(jq -r '.account_kind' <<<"${row}")"
  account_for "${account_kind}"
}

validate_matrix_provider() {
  local provider="$1" provisioner
  provisioner="$(jq -r --arg provider "${provider}" '.[$provider].provisioner // empty' "${REGISTRY_FILE}")"
  case "${provisioner}" in
    terraform|existing) ;;
    *) echo "::error::Provider ${provider} is not present in the provider registry or has an unsupported provisioner" >&2; return 1 ;;
  esac
}

wait_for_run() {
  local workflow="$1" started="$2" label="$3" run_id=""
  for _ in $(seq 1 45); do
    run_id="$(gh run list --repo "${GH_REPO}" --workflow "${workflow}" --event workflow_dispatch --limit 50 --json databaseId,createdAt,headBranch --jq "[.[] | select(.headBranch == \"${CHILD_REF}\" and .createdAt >= \"${started}\")] | sort_by(.createdAt) | last | .databaseId // empty")"
    [[ -n "${run_id}" ]] && break
    sleep 2
  done
  [[ -n "${run_id}" ]] || { echo "::error::Could not locate ${workflow} run for ${label}" >&2; return 1; }
  echo "${label}: dispatched ${workflow} run ${run_id}"
  gh run watch "${run_id}" --repo "${GH_REPO}" --interval "${WAIT_INTERVAL_SECONDS}" --exit-status --compact
  echo "${label}: ${workflow} run ${run_id} succeeded"
}

dispatch_and_wait() {
  local workflow="$1" payload="$2" label="$3"
  if [[ "${DRY_RUN}" == true ]]; then
    echo "DRY-RUN ${label}: ${workflow} ${payload}"
    return 0
  fi
  local started
  started="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  gh api --method POST "repos/${GH_REPO}/actions/workflows/${workflow}/dispatches" --input - <<<"${payload}" >/dev/null
  wait_for_run "${workflow}" "${started}" "${label}"
}

dispatch_selfhost() {
  local child_operation="$1" namespace="$2" provider="$3" account="$4" profile="$5" agent_profile="$6" existing_host="${7:-}" payload
  payload="$(jq -n \
    --arg ref "${CHILD_REF}" --arg runner_type "${RUNNER_TYPE}" --arg deploy_tag "${DEPLOY_TAG}" \
    --arg source_ref "${SOURCE_REF}" --arg operation "${child_operation}" --arg target_domains "${namespace}" \
    --arg provider "${provider}" --arg account "${account}" --arg profile "${profile}" --arg agent_profile "${agent_profile}" \
    --arg target_domain_base "${TARGET_DOMAIN_BASE}" --arg observability_endpoint "${OBSERVABILITY_ENDPOINT}" \
    --arg vault_addr "${VAULT_ADDR}" --arg gateway "${XCONNECT_GATEWAY_REF}" \
    --arg existing_host "${existing_host}" \
    '{ref:$ref,inputs:{runner_type:$runner_type,deploy_tag:$deploy_tag,source_ref:$source_ref,offline_mode:"off",source_host:"install.svc.plus",source_domain_base:"svc.plus",target_domain_base:$target_domain_base,observability_endpoint:$observability_endpoint,operation:$operation,target_domains:$target_domains,cloud_provider:$provider,cloud_account:$account,include_external_agent_proxy:"false",instance_plan:$profile,agent_proxy_plan:$agent_profile,dns_mode:"none",vault_env_path:"uat",skip_stripe_catalog:"true",agent_controller_url:"https://accounts-serverless-uat.onwalk.net",vault_addr:$vault_addr,xconnect_gateway_ref:$gateway,existing_target_host:$existing_host}}')"
  dispatch_and_wait selfhost-orchestrator.yml "${payload}" "${namespace} (${provider}, ${profile}, agent=${agent_profile})"
}

dispatch_serverless() {
  local child_operation="$1" target_domains="${2:-all}" payload
  # Pages/Workers is the public SSR/edge gateway. It receives both origins
  # from GitOps and applies selfhost-first routing; Cloud Run remains the
  # elastic/fallback origin for web-saas, not a replacement for its full-stack
  # Selfhost backend.
  payload="$(jq -n --arg ref "${CHILD_REF}" --arg operation "${child_operation}" --arg tag "${DEPLOY_TAG}" --arg target_domains "${target_domains}" '{ref:$ref,inputs:{operation:$operation,target_domains:$target_domains,cloud_provider:"gcp-cloud",vault_env_path:"uat",tag_ref:$tag,deploy_cloudflare:"true",deploy_cloud_run:"true",skip_stripe_catalog:"true",dns_mode:"none",runner_type:"ubuntu-latest"}}')"
  dispatch_and_wait serverless-orchestrator.yml "${payload}" "web-saas serverless"
}

# The Existing UAT One workflow is a migration-only path. It reads the
# protected source record under prod/ulighthost-xconnect and must never be a
# prerequisite of an ordinary deploy. New open-platform/GCP resources and
# business nodes use their declared runtime/network integration instead.
dispatch_xconnect_migration() {
  local payload
  payload="$(jq -n \
    --arg ref "${CHILD_REF}" \
    --arg gateway_ref "${XCONNECT_GATEWAY_REF}" \
    --arg network_id "${XCONNECT_NETWORK_ID}" \
    --arg gateway_vault_key "${XCONNECT_GATEWAY_VAULT_KEY}" \
    --arg one_vault_key "${XCONNECT_ONE_VAULT_KEY}" \
    --arg gateway_id "${XCONNECT_GATEWAY_ID}" \
    '{ref:$ref,inputs:{deployment_profile:"existing-one",mode:"apply",gateway_provider:"external",external_gateway_id:$gateway_id,external_network_id:$network_id,network_id:$network_id,external_gateway_server_name:$gateway_ref,gateway_vault_key:$gateway_vault_key,one_vault_key:$one_vault_key,matrix_node_filter:"all"}}')"
  dispatch_and_wait xconnect-zero-cloud.yaml "${payload}" "XConnect Zero UAT (${XCONNECT_GATEWAY_REF})"
}

dispatch_existing() {
  local namespace="$1" manifest="$2" account="$3" payload
  payload="$(jq -n --arg ref "${CHILD_REF}" --arg account "${account}" --arg manifest "${manifest}" '{ref:$ref,inputs:{cloud_provider:"ulighthost",vault_env_path:"uat",project:"svc.plus",account:$account,workspace:"xconnect",resource_manifest:$manifest,gitops_repo_name:"ai-workspace-infra/gitops",gitops_repo_ref:"main"}}')"
  dispatch_and_wait external-inventory-state.yml "${payload}" "${namespace} (existing inventory)"
}

mapfile -t rows < <(jq -c '(.spec.resources // .resources) | sort_by(.order)[]' "${MATRIX_FILE}")
[[ "${#rows[@]}" -eq 8 ]] || { echo "::error::Hybrid matrix must contain exactly eight resources" >&2; exit 1; }

# XConnect is a separate network contract, not a provider/account property of
# any Terraform namespace. Keep its public identity in GitOps and its runtime
# material in Vault. The fallback preserves compatibility with the existing
# UAT declaration while the catalog is rolled out.
XCONNECT_NETWORK_ID="$(jq -r '.spec.xconnect_network.id // "net_uat"' "${MATRIX_FILE}")"
XCONNECT_GATEWAY_REF="$(jq -r '.spec.xconnect_network.gateway_ref // empty' "${MATRIX_FILE}")"
XCONNECT_GATEWAY_VAULT_KEY="$(jq -r '.spec.xconnect_network.gateway_vault_key // "tw-xconnect.svc.plus"' "${MATRIX_FILE}")"
XCONNECT_ONE_VAULT_KEY="$(jq -r '.spec.xconnect_network.one_vault_key // "observability.svc.plus"' "${MATRIX_FILE}")"
XCONNECT_GATEWAY_ID="$(jq -r '.spec.xconnect_network.gateway_id // "gw-uat-tw-xconnect"' "${MATRIX_FILE}")"
[[ "${XCONNECT_NETWORK_ID}" =~ ^net_[A-Za-z0-9][A-Za-z0-9_-]{1,62}$ ]] || {
  echo "::error::GitOps XConnect network id is invalid: ${XCONNECT_NETWORK_ID}" >&2
  exit 1
}
[[ "${XCONNECT_GATEWAY_REF}" =~ ^[A-Za-z0-9.-]+$ ]] || {
  echo "::error::GitOps XConnect Gateway ref is invalid: ${XCONNECT_GATEWAY_REF}" >&2
  exit 1
}

validate_release_scopes() {
  local row namespace scope
  for row in "${rows[@]}"; do
    namespace="$(jq -r '.namespace' <<<"${row}")"
    scope="$(jq -r '.release_scope // "business"' <<<"${row}")"
    case "${scope}" in
      business|shared-infrastructure) ;;
      *) echo "::error::Unsupported release_scope=${scope} for ${namespace}" >&2; return 1 ;;
    esac
  done
}

validate_release_scopes

skip_shared_service_release() {
  local row="$1" namespace scope
  namespace="$(jq -r '.namespace' <<<"${row}")"
  scope="$(jq -r '.release_scope // "business"' <<<"${row}")"
  if [[ "${OPERATION}" == deploy && "${scope}" == shared-infrastructure ]]; then
    echo "${namespace}: release_scope=${scope}; skipping routine UAT business release"
    return 0
  fi
  return 1
}

if [[ "${OPERATION}" == deploy ]]; then
  # A deploy has a network prerequisite that cannot be satisfied by the
  # historical single-pass matrix: all new Terraform hosts must exist before
  # the external TW Gateway is enrolled into the UAT Zero Trust network.
  # open-platform is deployed in the first phase because it owns the platform
  # services; the three regional proxy lanes are provisioned only in phase 1.
  # Their application Playbooks run after XConnect succeeds.
  echo "::group::UAT hybrid deploy phase 1: Terraform resources"
  for row in "${rows[@]}"; do
    namespace="$(jq -r '.namespace' <<<"${row}")"
    mode="$(jq -r '.management_mode' <<<"${row}")"
    [[ "${mode}" == terraform ]] || continue
    provider="$(jq -r '.provider' <<<"${row}")"
    validate_matrix_provider "${provider}"
    account="$(account_for_row "${row}")"
    [[ -n "${account}" ]] || { echo "::error::No concrete account configured for ${provider} row ${namespace}; set the matching workflow account input." >&2; exit 1; }
    profile="$(jq -r '.profile' <<<"${row}")"
    agent_profile="$(jq -r '.agent_profile // "1C2G"' <<<"${row}")"
    if [[ "${namespace}" == open-platform ]]; then
      dispatch_selfhost deploy "${namespace}" "${provider}" "${account}" "${profile}" "${agent_profile}"
    else
      dispatch_selfhost infra "${namespace}" "${provider}" "${account}" "${profile}" "${agent_profile}"
    fi
  done
  echo "::endgroup::"

  # The protected legacy observability One is a migration source only. Normal
  # UAT deploys use the GitOps-declared persistent TW Gateway and must not read
  # or SSH to kv/prod/ulighthost-xconnect/observability.svc.plus. The explicit
  # migration switch keeps the old enrollment path available for a separately
  # reviewed migration run.
  if [[ "${XCONNECT_MIGRATION}" == true ]]; then
    echo "::group::UAT hybrid deploy gate: explicit XConnect One migration"
    dispatch_xconnect_migration
    echo "::endgroup::"
  else
    echo 'XConnect One migration gate disabled; using the GitOps-declared UAT Gateway without touching the protected legacy source.'
  fi

  echo "::group::UAT hybrid deploy phase 2: Applications and existing nodes"
  for row in "${rows[@]}"; do
    namespace="$(jq -r '.namespace' <<<"${row}")"
    mode="$(jq -r '.management_mode' <<<"${row}")"
    provider="$(jq -r '.provider' <<<"${row}")"
    account="$(account_for_row "${row}")"
    profile="$(jq -r '.profile' <<<"${row}")"
    agent_profile="$(jq -r '.agent_profile // "1C2G"' <<<"${row}")"
    existing_host="$(jq -r '.existing_host // empty' <<<"${row}")"
    case "${mode}" in
      terraform)
        [[ "${namespace}" == open-platform ]] && continue
        dispatch_selfhost deploy "${namespace}" "${provider}" "${account}" "${profile}" "${agent_profile}"
        ;;
      terraform+serverless)
        dispatch_selfhost deploy "${namespace}" "${provider}" "${account}" "${profile}" "${agent_profile}"
        dispatch_serverless deploy "$(jq -r '.serverless_target // "all"' <<<"${row}")"
        ;;
      existing+serverless)
        existing_node="$(jq -r '.existing_node // "vault-node-0"' <<<"${row}")"
        echo "${namespace}: reusing existing ${provider} node ${existing_node}; no Terraform state mutation"
        dispatch_serverless deploy "$(jq -r '.serverless_target // "all"' <<<"${row}")"
        ;;
      existing-selfhost)
        [[ -n "${existing_host}" ]] || { echo "::error::${namespace} existing-selfhost row requires existing_host" >&2; exit 1; }
        dispatch_selfhost deploy "${namespace}" "${provider}" "${account}" "${profile}" "${agent_profile}" "${existing_host}"
        ;;
      existing)
        [[ "${provider}" == ulighthost ]] || { echo "::error::existing rows must use the external-inventory adapter provider (ulighthost)" >&2; exit 1; }
        dispatch_existing "${namespace}" "$(jq -r '.resource_manifest' <<<"${row}")" "${account}"
        ;;
      *) echo "::error::unsupported management_mode ${mode}" >&2; exit 1 ;;
    esac
  done
  echo "::endgroup::"
  if [[ "${XCONNECT_MIGRATION}" == true ]]; then
    echo "Hybrid UAT deploy completed: Terraform readiness -> explicit XConnect One migration -> applications and existing nodes."
  else
    echo "Hybrid UAT deploy completed: Terraform readiness -> GitOps-declared XConnect Gateway -> applications and existing nodes; protected legacy source untouched."
  fi
  exit 0
fi

previous_order=0
for row in "${rows[@]}"; do
  order="$(jq -r '.order' <<<"${row}")"
  [[ "${order}" -eq $((previous_order + 1)) ]] || { echo "::error::matrix order is not contiguous at ${order}" >&2; exit 1; }
  previous_order="${order}"
  namespace="$(jq -r '.namespace' <<<"${row}")"
  mode="$(jq -r '.management_mode' <<<"${row}")"
  provider="$(jq -r '.provider' <<<"${row}")"
  validate_matrix_provider "${provider}"
  account="$(account_for_row "${row}")"
  [[ -n "${account}" ]] || { echo "::error::No concrete account configured for ${provider} row ${namespace}; set the matching workflow account input." >&2; exit 1; }
  profile="$(jq -r '.profile' <<<"${row}")"
  agent_profile="$(jq -r '.agent_profile // "1C2G"' <<<"${row}")"
  existing_host="$(jq -r '.existing_host // empty' <<<"${row}")"
  echo "::group::UAT hybrid ${order}/8 ${namespace} (${mode})"
  case "${OPERATION}" in plan) child_operation=plan; serverless_operation=plan ;; apply) child_operation=infra; serverless_operation=plan ;; deploy) child_operation=deploy; serverless_operation=deploy ;; destroy) child_operation=destroy; serverless_operation=destroy ;; esac
  case "${mode}" in
    terraform)
      if [[ "${OPERATION}" == destroy && "$(jq -r '.lifecycle // ""' <<<"${row}")" != ephemeral ]]; then
        echo "${namespace}: lifecycle is protected; skipping destroy"
      else
        dispatch_selfhost "${child_operation}" "${namespace}" "${provider}" "${account}" "${profile}" "${agent_profile}"
      fi
      ;;
    terraform+serverless) dispatch_selfhost "${child_operation}" "${namespace}" "${provider}" "${account}" "${profile}" "${agent_profile}"; dispatch_serverless "${serverless_operation}" "$(jq -r '.serverless_target // "all"' <<<"${row}")" ;;
    existing+serverless) existing_node="$(jq -r '.existing_node // "vault-node-0"' <<<"${row}")"; echo "${namespace}: reusing existing ${provider} node ${existing_node}; no Terraform state mutation"; dispatch_serverless "${serverless_operation}" "$(jq -r '.serverless_target // "all"' <<<"${row}")" ;;
    existing-selfhost)
      [[ -n "${existing_host}" ]] || { echo "::error::${namespace} existing-selfhost row requires existing_host" >&2; exit 1; }
      if [[ "${OPERATION}" == destroy ]]; then
        echo "${namespace}: existing host ${existing_host} is protected; skipping destroy"
      else
        if [[ "${OPERATION}" == apply ]]; then child_operation=plan; fi
        dispatch_selfhost "${child_operation}" "${namespace}" "${provider}" "${account}" "${profile}" "${agent_profile}" "${existing_host}"
      fi
      ;;
    existing)
      [[ "$(jq -r '.provider' <<<"${row}")" == ulighthost ]] || { echo "::error::existing rows must use the external-inventory adapter provider (ulighthost)" >&2; exit 1; }
      if [[ "${OPERATION}" == destroy ]]; then
        echo "${namespace}: existing inventory is protected; skipping destroy"
      else
        dispatch_existing "${namespace}" "$(jq -r '.resource_manifest' <<<"${row}")" "${account}"
      fi
      ;;
    *) echo "::error::unsupported management_mode ${mode}" >&2; exit 1 ;;
  esac
  echo "::endgroup::"
done

echo "Hybrid UAT matrix completed: eight ordered resource lanes, no shared Terraform state."
