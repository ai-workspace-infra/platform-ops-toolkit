#!/usr/bin/env bash
# Writes the one-time GCP bootstrap credential for gcp-oidc-bootstrap.yml into
# Vault kv/CICD/<env>/gcp-bootstrap/<account>.
#
#   default (token mode)  GCP_ACCESS_TOKEN: short-lived admin OAuth token from
#                         the caller's ADC. No org policy change required.
#   --auth-json           GCP_AUTH_JSON: key of a dedicated gcp-bootstrap-<env>
#                         service account with the four bootstrap roles only.
#                         Requires iam.disableServiceAccountKeyCreation to be
#                         lifted for the target project; the key is one-time and
#                         must be revoked after bootstrap (action=revoke, or the
#                         workflow's own revoke step).
#
# GCP_BOOTSTRAP_ACTION: write (default) | check | revoke
# Daily IaC pipelines never read this path; they use GitHub OIDC -> Vault JWT
# role -> Google WIF only.
set -euo pipefail

credential_mode="token"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --auth-json) credential_mode="auth_json" ;;
    -h|--help) sed -n '2,17p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1 (supported: --auth-json)" >&2; exit 1 ;;
  esac
  shift
done

environment="${GCP_ENVIRONMENT:?GCP_ENVIRONMENT is required (uat, prod, or shared)}"
account_id="${GCP_ACCOUNT_ID:?GCP_ACCOUNT_ID is required}"
project_id="${GCP_PROJECT_ID:?GCP_PROJECT_ID is required}"
vault_addr="${VAULT_ADDR:-https://vault.svc.plus}"
action="${GCP_BOOTSTRAP_ACTION:-write}"

case "${environment}" in
  uat) default_project="open-platform-uat" ;;
  prod) default_project="open-platform-prod" ;;
  shared) default_project="open-platform-prod" ;;
  *) echo "GCP_ENVIRONMENT must be uat, prod, or shared" >&2; exit 1 ;;
esac
if [[ "${environment}" == shared && "${account_id}" != "open-platform-prod" ]]; then
  echo "shared GCP bootstrap requires GCP_ACCOUNT_ID=open-platform-prod" >&2
  exit 1
fi
if [[ "${environment}" == shared && "${credential_mode}" == auth_json ]]; then
  echo "shared GCP bootstrap accepts only a short-lived GCP_ACCESS_TOKEN; long-lived SA keys are disabled" >&2
  exit 1
fi
[[ "${account_id}" =~ ^[A-Za-z0-9][A-Za-z0-9._%+@-]{0,126}[A-Za-z0-9]$ ]] || {
  echo "GCP_ACCOUNT_ID must be a stable name or email-like identifier without '/'" >&2
  exit 1
}
[[ "${project_id}" =~ ^[a-z][a-z0-9-]{4,28}[a-z0-9]$ ]] || {
  echo "GCP_PROJECT_ID must be a valid GCP project ID" >&2
  exit 1
}
[[ "${vault_addr}" =~ ^https?://[^/]+/?$ ]] || {
  echo "VAULT_ADDR must be an https:// or http:// Vault URL" >&2
  exit 1
}
command -v jq >/dev/null 2>&1 || { echo "jq is required" >&2; exit 1; }

# xworktech is the initial account contract. Additional accounts must provide
# an explicit project mapping; silently accepting an arbitrary project would
# allow a caller to write one account's bootstrap token under another target.
expected_project="${GCP_EXPECTED_PROJECT_ID:-}"
if [[ -z "${expected_project}" ]]; then
  if [[ "${environment}" == shared && "${account_id}" == "open-platform-prod" ]]; then
    expected_project="open-platform-prod"
  elif [[ "${account_id}" == "xworktech" ]]; then
    expected_project="${default_project}"
  else
    echo "GCP_EXPECTED_PROJECT_ID is required for non-xworktech accounts" >&2
    exit 1
  fi
fi
if [[ "${project_id}" != "${expected_project}" ]]; then
  echo "GCP_PROJECT_ID does not match GCP_ENVIRONMENT/account" >&2
  exit 1
fi

secret_path="CICD/${environment}/gcp-bootstrap/${account_id}"
api_url="${vault_addr%/}/v1/kv/data/${secret_path}"

vault_cli_session_available() {
  command -v vault >/dev/null 2>&1 &&
    VAULT_ADDR="${vault_addr}" vault token lookup >/dev/null 2>&1
}

vault_read_json() {
  if [[ -n "${VAULT_TOKEN:-}" ]]; then
    command -v curl >/dev/null 2>&1 || { echo "curl is required with VAULT_TOKEN" >&2; exit 1; }
    curl --fail --silent --show-error \
      --header "X-Vault-Token: ${VAULT_TOKEN}" "${api_url}"
  else
    vault_cli_session_available || {
      echo "Vault authentication is required: set VAULT_TOKEN or run 'vault login'" >&2
      exit 1
    }
    VAULT_ADDR="${vault_addr}" vault kv get -mount=kv -format=json "${secret_path}"
  fi
}

vault_write_json() {
  if [[ -n "${VAULT_TOKEN:-}" ]]; then
    command -v curl >/dev/null 2>&1 || { echo "curl is required with VAULT_TOKEN" >&2; exit 1; }
    curl --fail --silent --show-error \
      --header "X-Vault-Token: ${VAULT_TOKEN}" \
      --header "Content-Type: application/json" \
      --request POST --data-binary @- "${api_url}" >/dev/null
  else
    vault_cli_session_available || {
      echo "Vault authentication is required: set VAULT_TOKEN or run 'vault login'" >&2
      exit 1
    }
    # KV CLI input is a flat object (the HTTP API wrapper is not accepted).
    input_file="$(mktemp "${TMPDIR:-/tmp}/gcp-bootstrap-input.XXXXXX")"
    payload_file="$(mktemp "${TMPDIR:-/tmp}/gcp-bootstrap-payload.XXXXXX")"
    trap 'rm -f "${input_file}" "${payload_file}"' RETURN
    cat >"${input_file}"
    jq -e '.data | type == "object"' "${input_file}" >/dev/null
    jq '.data' "${input_file}" >"${payload_file}"
    VAULT_ADDR="${vault_addr}" vault kv put -mount=kv "${secret_path}" "@${payload_file}" >/dev/null
    rm -f "${input_file}" "${payload_file}"
    trap - RETURN
  fi
}

bootstrap_sa_id="gcp-bootstrap-${environment}"
bootstrap_sa_email="${bootstrap_sa_id}@${project_id}.iam.gserviceaccount.com"
# Exactly the permissions the bootstrap preflight and Terraform need; never
# Owner/Editor. Keep in sync with GCP-OIDC-Bootstrap-howto.md.
bootstrap_roles=(
  roles/iam.workloadIdentityPoolAdmin
  roles/iam.serviceAccountAdmin
  roles/resourcemanager.projectIamAdmin
  roles/serviceusage.serviceUsageAdmin
)

require_gcloud() {
  command -v gcloud >/dev/null 2>&1 || { echo "gcloud is required for --auth-json" >&2; exit 1; }
  gcloud projects describe "${project_id}" --format='value(projectId)' >/dev/null 2>&1 || {
    echo "Active gcloud account cannot access project ${project_id}" >&2
    exit 1
  }
}

vault_delete_all_versions() {
  if [[ -n "${VAULT_TOKEN:-}" ]]; then
    curl --fail --silent --show-error --request DELETE \
      --header "X-Vault-Token: ${VAULT_TOKEN}" \
      "${vault_addr%/}/v1/kv/metadata/${secret_path}" >/dev/null
  else
    vault_cli_session_available || {
      echo "Vault authentication is required: set VAULT_TOKEN or run 'vault login'" >&2
      exit 1
    }
    VAULT_ADDR="${vault_addr}" vault kv metadata delete -mount=kv "${secret_path}" >/dev/null
  fi
}

# Fails fast with remediation when the org-wide key creation ban applies.
preflight_key_creation_policy() {
  local policy enforced
  if ! policy="$(gcloud org-policies describe iam.disableServiceAccountKeyCreation \
      --project="${project_id}" --effective --format=json 2>/dev/null)"; then
    echo "warning: could not read effective org policy; key creation may still be denied" >&2
    return 0
  fi
  enforced="$(jq -r '[.spec.rules[]?.enforce] | any' <<<"${policy}")"
  if [[ "${enforced}" == "true" ]]; then
    cat >&2 <<EOF
iam.disableServiceAccountKeyCreation is enforced for ${project_id}.
--auth-json needs a temporary project-level exception (requires roles/orgpolicy.policyAdmin):

  cat > /tmp/allow-sa-key.yaml <<'YAML'
  name: projects/${project_id}/policies/iam.disableServiceAccountKeyCreation
  spec:
    rules:
    - enforce: false
  YAML
  gcloud org-policies set-policy /tmp/allow-sa-key.yaml

Restore the org default after bootstrap and revoke:
  gcloud org-policies delete iam.disableServiceAccountKeyCreation --project=${project_id}

Or run without --auth-json to use a short-lived admin token (no policy change).
EOF
    exit 1
  fi
}

ensure_bootstrap_service_account() {
  if gcloud iam service-accounts describe "${bootstrap_sa_email}" --project="${project_id}" >/dev/null 2>&1; then
    gcloud iam service-accounts enable "${bootstrap_sa_email}" --project="${project_id}" --quiet >/dev/null
  else
    gcloud iam service-accounts create "${bootstrap_sa_id}" --project="${project_id}" \
      --display-name="GCP OIDC bootstrap (${environment}, one-time)" \
      --description="One-time bootstrap identity for gcp-oidc-bootstrap.yml; key revoked after use" >/dev/null
  fi
  local role
  for role in "${bootstrap_roles[@]}"; do
    gcloud projects add-iam-policy-binding "${project_id}" \
      --member="serviceAccount:${bootstrap_sa_email}" --role="${role}" \
      --condition=None --quiet >/dev/null
  done
}

write_auth_json() {
  require_gcloud
  preflight_key_creation_policy
  ensure_bootstrap_service_account

  local key_dir key_file key_id
  key_dir="$(mktemp -d "${TMPDIR:-/tmp}/gcp-bootstrap-key.XXXXXX")"
  chmod 700 "${key_dir}"
  key_file="${key_dir}/key.json"
  trap 'rm -rf "${key_dir}"' EXIT
  ( umask 077 && gcloud iam service-accounts keys create "${key_file}" \
      --iam-account="${bootstrap_sa_email}" --project="${project_id}" --quiet >/dev/null )

  jq -e --arg project "${project_id}" --arg email "${bootstrap_sa_email}" \
    '.type == "service_account" and .project_id == $project and .client_email == $email' \
    "${key_file}" >/dev/null || { echo "Generated key does not match ${bootstrap_sa_email}" >&2; exit 1; }
  key_id="$(jq -r '.private_key_id' "${key_file}")"

  # kv put replaces the whole secret: any previous GCP_ACCESS_TOKEN is dropped
  # so exactly one bootstrap credential exists at a time.
  jq -n --rawfile auth "${key_file}" --arg project "${project_id}" \
    --arg sa "${bootstrap_sa_email}" --arg key_id "${key_id}" \
    '{data:{GCP_AUTH_JSON:($auth|fromjson|tojson),GCP_PROJECT_ID:$project,
            GCP_BOOTSTRAP_SERVICE_ACCOUNT:$sa,GCP_AUTH_KEY_ID:$key_id}}' |
    vault_write_json
  rm -rf "${key_dir}"
  trap - EXIT
  echo "${secret_path}: GCP_AUTH_JSON written (service account ${bootstrap_sa_email}, key ${key_id})"
  echo "Revoke after bootstrap: GCP_BOOTSTRAP_ACTION=revoke $0"
}

revoke_auth_json() {
  require_gcloud
  local current sa key_id
  current="$(vault_read_json)"
  sa="$(jq -r '.data.data.GCP_BOOTSTRAP_SERVICE_ACCOUNT // empty' <<<"${current}")"
  key_id="$(jq -r '.data.data.GCP_AUTH_KEY_ID // empty' <<<"${current}")"
  sa="${sa:-${bootstrap_sa_email}}"
  if [[ -n "${key_id}" ]]; then
    gcloud iam service-accounts keys delete "${key_id}" --iam-account="${sa}" \
      --project="${project_id}" --quiet >/dev/null 2>&1 || echo "key ${key_id} already absent"
  fi
  gcloud iam service-accounts disable "${sa}" --project="${project_id}" --quiet >/dev/null 2>&1 ||
    echo "service account ${sa} already disabled or absent"
  # Destroy every version that ever held the key, then keep only the project ID.
  vault_delete_all_versions
  jq -n --arg project "${project_id}" '{data:{GCP_PROJECT_ID:$project}}' | vault_write_json
  echo "${secret_path}: bootstrap credential revoked (key ${key_id:-n/a}, ${sa} disabled)"
}

revoke_access_token() {
  local current access_token
  current="$(vault_read_json)"
  access_token="$(jq -r '.data.data.GCP_ACCESS_TOKEN // empty' <<<"${current}")"
  if [[ -n "${access_token}" ]]; then
    export GCP_REVOKE_ACCESS_TOKEN="${access_token}"
    if jq -rn '"token=" + (env.GCP_REVOKE_ACCESS_TOKEN | @uri)' |
      curl --fail --silent --show-error --request POST \
        --header 'Content-Type: application/x-www-form-urlencoded' \
        --data-binary @- "https://oauth2.googleapis.com/revoke" >/dev/null; then
      echo "GCP access token revoked."
    else
      echo "warning: token revocation endpoint failed; the token will expire naturally" >&2
    fi
    unset GCP_REVOKE_ACCESS_TOKEN access_token
  fi
  vault_delete_all_versions
  jq -n --arg project "${project_id}" '{data:{GCP_PROJECT_ID:$project}}' | vault_write_json
  echo "${secret_path}: token removed; only GCP_PROJECT_ID remains"
}

case "${action}:${credential_mode}" in
  check:token)
    vault_read_json |
      jq -e --arg project "${project_id}" \
        '.data.data |
         (.GCP_ACCESS_TOKEN | type == "string" and length > 0) and
         (.GCP_PROJECT_ID | type == "string" and . == $project)' \
        >/dev/null
    echo "${secret_path}: OK"
    ;;
  check:auth_json)
    vault_read_json |
      jq -e --arg project "${project_id}" \
        '.data.data |
         (.GCP_AUTH_JSON | type == "string" and (fromjson | .type == "service_account" and .project_id == $project)) and
         (.GCP_PROJECT_ID | type == "string" and . == $project)' \
        >/dev/null
    echo "${secret_path}: OK (GCP_AUTH_JSON)"
    ;;
  write:token)
    access_token="${GCP_ACCESS_TOKEN:-}"
    if [ -z "${access_token}" ]; then
      command -v gcloud >/dev/null 2>&1 || { echo "gcloud is required when GCP_ACCESS_TOKEN is unset" >&2; exit 1; }
      if ! access_token="$(gcloud auth application-default print-access-token)"; then
        echo "Unable to obtain a GCP access token. Run: gcloud auth application-default login" >&2
        exit 1
      fi
    fi
    test -n "${access_token}" || { echo "GCP access token is empty" >&2; exit 1; }
    GCP_ACCESS_TOKEN="${access_token}" GCP_PROJECT_ID="${project_id}" jq -n \
      '{data:{GCP_ACCESS_TOKEN:env.GCP_ACCESS_TOKEN,GCP_PROJECT_ID:env.GCP_PROJECT_ID}}' |
      vault_write_json
    unset access_token GCP_ACCESS_TOKEN
    echo "${secret_path}: written"
    ;;
  write:auth_json)
    write_auth_json
    ;;
  revoke:*)
    current_secret="$(vault_read_json)"
    if jq -e '.data.data.GCP_AUTH_JSON | type == "string" and length > 0' <<<"${current_secret}" >/dev/null; then
      revoke_auth_json
    elif jq -e '.data.data.GCP_ACCESS_TOKEN | type == "string" and length > 0' <<<"${current_secret}" >/dev/null; then
      revoke_access_token
    else
      echo "${secret_path}: no bootstrap credential is present; nothing to revoke" >&2
      exit 1
    fi
    ;;
  *)
    echo "GCP_BOOTSTRAP_ACTION must be write, check or revoke" >&2
    exit 1
    ;;
esac
