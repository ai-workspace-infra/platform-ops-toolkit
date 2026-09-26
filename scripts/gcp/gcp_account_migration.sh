#!/usr/bin/env bash
# Parameterized GCP account migration helper.
#
# Subcommands:
#   plan      read-only checks
#   prepare   optionally link billing, enable APIs, write bootstrap KV
#   dispatch  dispatch the GitHub OIDC bootstrap workflow
#   finalize  write WIF runtime identity into serverless KV
#
# Project IDs, regions, billing accounts, GitOps paths, Vault address and
# workflow values are supplied by flags or environment variables. Secrets are
# never printed.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

die() { echo "gcp_account_migration: $*" >&2; exit 1; }
usage() {
  cat <<'USAGE'
Usage: gcp_account_migration.sh {plan|prepare|dispatch|finalize} [options]

Required (flags or environment):
  --environment ENV       GCP_ENVIRONMENT (uat|prod)
  --project-id ID         GCP_PROJECT_ID
  --region REGION         GCP_REGION
  --account-id ID         GCP_ACCOUNT_ID
  --gitops-manifest FILE  GCP_GITOPS_MANIFEST
  --oidc-config FILE      GCP_OIDC_CONFIG

Optional:
  --billing-account ID    GCP_BILLING_ACCOUNT
  --vault-addr URL        VAULT_ADDR
  --link-billing          allow prepare to link the billing account
  --skip-api-enable       do not enable APIs during prepare
  --skip-bootstrap        do not write the bootstrap KV during prepare
  --token-source SOURCE   auto|adc|gcloud for bootstrap token (default: auto)
  --bootstrap-action A    plan|apply for dispatch (default: plan)
  --provider NAME         WIF provider resource name for finalize
  --service-account EMAIL deploy Service Account email for finalize
  --repository OWNER/REPO GITHUB_REPOSITORY
  --workflow FILE         GITHUB_WORKFLOW (default: gcp-oidc-bootstrap.yml)
  --workflow-ref REF      GITHUB_WORKFLOW_REF (default: main)
  -h, --help

GCP_REQUIRED_APIS may override the space-separated API list.
USAGE
}

if [[ $# -eq 0 || "${1}" == -* ]]; then
  subcommand="plan"
else
  subcommand="$1"
  shift
fi
case "${subcommand}" in plan|prepare|dispatch|finalize) ;; *) usage; die "invalid subcommand" ;; esac

environment="${GCP_ENVIRONMENT:-}"
project_id="${GCP_PROJECT_ID:-}"
region="${GCP_REGION:-}"
account_id="${GCP_ACCOUNT_ID:-}"
manifest="${GCP_GITOPS_MANIFEST:-}"
oidc_config="${GCP_OIDC_CONFIG:-}"
billing_account="${GCP_BILLING_ACCOUNT:-}"
vault_addr="${VAULT_ADDR:-https://vault.svc.plus}"
bootstrap_action="${GITHUB_BOOTSTRAP_ACTION:-plan}"
provider_resource_name="${GCP_WORKLOAD_IDENTITY_PROVIDER:-}"
service_account_email="${GCP_SERVICE_ACCOUNT_EMAIL:-}"
github_repository="${GITHUB_REPOSITORY:-ai-workspace-infra/platform-ops-toolkit}"
workflow="${GITHUB_WORKFLOW:-gcp-oidc-bootstrap.yml}"
workflow_ref="${GITHUB_WORKFLOW_REF:-main}"
required_apis="${GCP_REQUIRED_APIS:-run.googleapis.com artifactregistry.googleapis.com secretmanager.googleapis.com sts.googleapis.com iamcredentials.googleapis.com}"
token_source="${GCP_TOKEN_SOURCE:-auto}"
link_billing=false
skip_api_enable=false
skip_bootstrap=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --environment) environment="${2:?missing --environment value}"; shift 2 ;;
    --project-id) project_id="${2:?missing --project-id value}"; shift 2 ;;
    --region) region="${2:?missing --region value}"; shift 2 ;;
    --account-id) account_id="${2:?missing --account-id value}"; shift 2 ;;
    --gitops-manifest) manifest="${2:?missing --gitops-manifest value}"; shift 2 ;;
    --oidc-config) oidc_config="${2:?missing --oidc-config value}"; shift 2 ;;
    --billing-account) billing_account="${2:?missing --billing-account value}"; shift 2 ;;
    --vault-addr) vault_addr="${2:?missing --vault-addr value}"; shift 2 ;;
    --link-billing) link_billing=true; shift ;;
    --skip-api-enable) skip_api_enable=true; shift ;;
    --skip-bootstrap) skip_bootstrap=true; shift ;;
    --token-source) token_source="${2:?missing --token-source value}"; shift 2 ;;
    --bootstrap-action) bootstrap_action="${2:?missing --bootstrap-action value}"; shift 2 ;;
    --provider) provider_resource_name="${2:?missing --provider value}"; shift 2 ;;
    --service-account) service_account_email="${2:?missing --service-account value}"; shift 2 ;;
    --repository) github_repository="${2:?missing --repository value}"; shift 2 ;;
    --workflow) workflow="${2:?missing --workflow value}"; shift 2 ;;
    --workflow-ref) workflow_ref="${2:?missing --workflow-ref value}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage; die "unknown option: $1" ;;
  esac
done

[[ "${environment}" =~ ^(uat|prod)$ ]] || die "environment must be uat or prod"
[[ "${project_id}" =~ ^[a-z][a-z0-9-]{4,28}[a-z0-9]$ ]] || die "invalid project id"
[[ "${region}" =~ ^[a-z0-9-]+$ ]] || die "invalid region"
[[ -n "${account_id}" && -f "${manifest}" && -f "${oidc_config}" ]] || die "account-id, GitOps manifest and OIDC config are required"
[[ "${bootstrap_action}" == plan || "${bootstrap_action}" == apply ]] || die "bootstrap-action must be plan or apply"
[[ "${vault_addr}" =~ ^https?://[^/]+/?$ ]] || die "invalid Vault address"
[[ "${token_source}" == auto || "${token_source}" == adc || "${token_source}" == gcloud ]] || die "token-source must be auto, adc or gcloud"

command -v gcloud >/dev/null 2>&1 || die "gcloud is required"
command -v ruby >/dev/null 2>&1 || die "ruby is required"
command -v jq >/dev/null 2>&1 || die "jq is required"

gitops_values="$(GCP_GITOPS_MANIFEST="${manifest}" ruby -e '
  require "yaml"; d=YAML.safe_load(File.read(ENV.fetch("GCP_GITOPS_MANIFEST")), permitted_classes: [], permitted_symbols: [], aliases: false); g=d.fetch("global"); puts g.fetch("project_id"); puts g.fetch("region")
')" || die "cannot read GitOps manifest"
[[ "$(sed -n '1p' <<<"${gitops_values}")" == "${project_id}" ]] || die "project does not match GitOps manifest"
[[ "$(sed -n '2p' <<<"${gitops_values}")" == "${region}" ]] || die "region does not match GitOps manifest"

oidc_values="$(GCP_OIDC_CONFIG="${oidc_config}" ruby -e '
  require "yaml"; d=YAML.safe_load(File.read(ENV.fetch("GCP_OIDC_CONFIG")), permitted_classes: [], permitted_symbols: [], aliases: false); s=d.fetch("spec"); puts s.fetch("pool_id"); puts s.fetch("provider_id"); puts s.fetch("service_account_id"); puts s.fetch("project_id")
')" || die "cannot read OIDC config"
pool_id="$(sed -n '1p' <<<"${oidc_values}")"
provider_id="$(sed -n '2p' <<<"${oidc_values}")"
service_account_id="$(sed -n '3p' <<<"${oidc_values}")"
[[ "$(sed -n '4p' <<<"${oidc_values}")" == "${project_id}" ]] || die "project does not match OIDC config"

active_account="$(gcloud config get-value account 2>/dev/null)"
project_number="$(gcloud projects describe "${project_id}" --format='value(projectNumber)')" || die "cannot read target project"
oidc_audience="https://iam.googleapis.com/projects/${project_number}/locations/global/workloadIdentityPools/${pool_id}/providers/${provider_id}"
expected_service_account="${service_account_id}@${project_id}.iam.gserviceaccount.com"

show_status() {
  echo "environment=${environment}"
  echo "project=${project_id}"
  echo "project_number=${project_number}"
  echo "region=${region}"
  echo "active_gcloud_account=${active_account}"
  echo "billing=$(gcloud billing projects describe "${project_id}" --format='value(billingEnabled,billingAccountName)' 2>/dev/null || true)"
  echo "wif_audience=${oidc_audience}"
  echo "deploy_service_account=${expected_service_account}"
}

show_api_state() {
  local enabled api missing=0
  enabled="$(gcloud services list --enabled --project="${project_id}" --format='value(config.name)' 2>/dev/null || true)"
  for api in ${required_apis}; do
    if grep -Fxq "${api}" <<<"${enabled}"; then echo "api=${api}:enabled"; else echo "api=${api}:missing"; missing=1; fi
  done
  return "${missing}"
}

vault_session() {
  command -v vault >/dev/null 2>&1 || die "vault is required"
  VAULT_ADDR="${vault_addr}" vault token lookup >/dev/null 2>&1 || die "Vault session unavailable; run vault login"
}

adc_session() {
  gcloud auth application-default print-access-token >/dev/null 2>&1
}

gcloud_session() {
  gcloud auth print-access-token >/dev/null 2>&1
}

bootstrap_token() {
  local token=""
  if [[ -n "${GCP_ACCESS_TOKEN:-}" ]]; then
    token="${GCP_ACCESS_TOKEN}"
  elif [[ "${token_source}" == adc ]]; then
    token="$(gcloud auth application-default print-access-token 2>/dev/null)" ||
      die "ADC token unavailable; use --token-source=gcloud or run gcloud auth application-default login"
  elif [[ "${token_source}" == gcloud ]]; then
    token="$(gcloud auth print-access-token 2>/dev/null)" ||
      die "active gcloud account token unavailable; run gcloud auth login"
  else
    token="$(gcloud auth application-default print-access-token 2>/dev/null || true)"
    if [[ -z "${token}" ]]; then
      token="$(gcloud auth print-access-token 2>/dev/null || true)"
    fi
    [[ -n "${token}" ]] || die "no short-lived GCP token available; run gcloud auth login or use --skip-bootstrap"
  fi
  [[ -n "${token}" ]] || die "GCP access token is empty"
  printf '%s' "${token}"
}

case "${subcommand}" in
  plan)
    show_status
    show_api_state || true
    if VAULT_ADDR="${vault_addr}" vault token lookup >/dev/null 2>&1; then echo "vault_session=available"; else echo "vault_session=unavailable"; fi
    if [[ -n "${GCP_ACCESS_TOKEN:-}" ]] || adc_session || gcloud_session; then
      echo "gcp_bootstrap_token=available (source=${token_source})"
    else
      echo "gcp_bootstrap_token=unavailable (source=${token_source}; use --skip-bootstrap or authenticate gcloud)"
    fi
    ;;
  prepare)
    if [[ "${skip_bootstrap}" != true ]]; then
      vault_session
      # Resolve the short-lived token before changing billing or API state so a
      # failed bootstrap credential check cannot leave a half-prepared project.
      bootstrap_access_token="$(bootstrap_token)"
    fi
    if [[ "${link_billing}" == true ]]; then
      [[ -n "${billing_account}" ]] || die "--billing-account is required with --link-billing"
      gcloud billing projects link "${project_id}" --billing-account="${billing_account}"
    fi
    [[ "${skip_api_enable}" == true ]] || gcloud services enable ${required_apis} --project="${project_id}"
    if [[ "${skip_bootstrap}" != true ]]; then
      GCP_ENVIRONMENT="${environment}" \
      GCP_ACCOUNT_ID="${account_id}" \
      GCP_PROJECT_ID="${project_id}" \
      GCP_EXPECTED_PROJECT_ID="${project_id}" \
      GCP_ACCESS_TOKEN="${bootstrap_access_token}" \
      VAULT_ADDR="${vault_addr}" \
        "${script_dir}/bootstrap_gcp_auth_kv.sh"
      unset bootstrap_access_token
    fi
    echo "prepare complete; dispatch the GitHub OIDC bootstrap workflow"
    ;;
  dispatch)
    command -v gh >/dev/null 2>&1 || die "gh is required for dispatch"
    gh workflow run "${workflow}" --repo "${github_repository}" --ref "${workflow_ref}" \
      -f "environment=${environment}" -f "action=${bootstrap_action}"
    echo "bootstrap workflow dispatched: ${environment}/${bootstrap_action}"
    ;;
  finalize)
    if [[ -z "${provider_resource_name}" ]]; then
      provider_resource_name="$(gcloud iam workload-identity-pools providers describe "${provider_id}" \
        --workload-identity-pool="${pool_id}" --location=global --project="${project_id}" --format='value(name)')" || die "WIF provider not found"
    fi
    [[ -n "${service_account_email}" ]] || service_account_email="${expected_service_account}"
    gcloud iam service-accounts describe "${service_account_email}" --project="${project_id}" --format='value(email)' >/dev/null || die "deploy Service Account not found"
    vault_session
    # KV v2 PUT replaces the data object, so legacy project/region keys are
    # removed and only the sensitive runtime identity fields remain.
    if [[ -n "${VAULT_TOKEN:-}" ]]; then
      payload="$(GCP_WIF_PROVIDER="${provider_resource_name}" GCP_SERVICE_ACCOUNT="${service_account_email}" jq -n '{data:{GCP_WORKLOAD_IDENTITY_PROVIDER:env.GCP_WIF_PROVIDER,GCP_SERVICE_ACCOUNT_EMAIL:env.GCP_SERVICE_ACCOUNT}}')"
      curl --fail --silent --show-error --header "X-Vault-Token: ${VAULT_TOKEN}" --header 'Content-Type: application/json' \
        --request POST --data-binary "${payload}" "${vault_addr%/}/v1/kv/data/${environment}/serverless/gcp" >/dev/null
      unset payload
    else
      VAULT_ADDR="${vault_addr}" vault kv put -mount=kv "${environment}/serverless/gcp" \
        "GCP_WORKLOAD_IDENTITY_PROVIDER=${provider_resource_name}" \
        "GCP_SERVICE_ACCOUNT_EMAIL=${service_account_email}" >/dev/null
    fi
    echo "Vault runtime identity updated: kv/${environment}/serverless/gcp (keys only)"
    ;;
esac
