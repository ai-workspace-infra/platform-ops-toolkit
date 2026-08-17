#!/usr/bin/env bash
set -euo pipefail

readonly API_BASE="https://api.cloudflare.com/client/v4"
readonly CONFIRMATION_REQUIRED="DELETE"

: "${CLOUDFLARE_ACCOUNT_ID:?CLOUDFLARE_ACCOUNT_ID is required}"
: "${CLOUDFLARE_API_TOKEN:?CLOUDFLARE_API_TOKEN is required}"
: "${CLEANUP_PAGES_PROJECTS:?CLEANUP_PAGES_PROJECTS is required}"
: "${CLEANUP_CONFIRMATION:?CLEANUP_CONFIRMATION is required}"

if [[ "${CLEANUP_CONFIRMATION}" != "${CONFIRMATION_REQUIRED}" ]]; then
  echo "CLEANUP_CONFIRMATION must be exactly ${CONFIRMATION_REQUIRED}" >&2
  exit 2
fi

dry_run="${CLEANUP_DRY_RUN:-false}"
if [[ "${dry_run}" != "true" && "${dry_run}" != "false" ]]; then
  echo "CLEANUP_DRY_RUN must be true or false" >&2
  exit 2
fi

api_request() {
  local method="$1"
  local url="$2"
  local response_file
  response_file="$(mktemp)"

  local http_code
  http_code="$(curl -sS --retry 3 --retry-delay 2 \
    -o "${response_file}" \
    -w '%{http_code}' \
    -X "${method}" \
    -H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" \
    -H 'Content-Type: application/json' \
    "${url}")"

  if [[ "${http_code}" != 2* ]] || ! jq -e '.success == true' "${response_file}" >/dev/null; then
    echo "Cloudflare API ${method} ${url} failed (HTTP ${http_code})" >&2
    jq -c '.errors // .messages // .' "${response_file}" >&2 || true
    rm -f "${response_file}"
    return 1
  fi

  cat "${response_file}"
  rm -f "${response_file}"
}

validate_project_name() {
  local project_name="$1"
  if [[ ! "${project_name}" =~ ^[a-z0-9][a-z0-9-]{0,62}$ ]]; then
    echo "Unsupported Pages project name: ${project_name}" >&2
    exit 2
  fi
}

get_deployments() {
  local project_name="$1"
  api_request GET "${API_BASE}/accounts/${CLOUDFLARE_ACCOUNT_ID}/pages/projects/${project_name}/deployments?page=1&per_page=100"
}

cleanup_project() {
  local project_name="$1"
  validate_project_name "${project_name}"
  echo "==> [Cloudflare Pages] Processing ${project_name}..."

  local project_json
  project_json="$(api_request GET "${API_BASE}/accounts/${CLOUDFLARE_ACCOUNT_ID}/pages/projects/${project_name}")"

  local production_id
  production_id="$(jq -r '.result.canonical_deployment.id // .result.latest_deployment.id // empty' <<<"${project_json}")"

  local deployments_json
  deployments_json="$(get_deployments "${project_name}")"

  if [[ -z "${production_id}" ]]; then
    production_id="$(jq -r --arg alias "${project_name}.pages.dev" \
      '.result[] | select((.aliases // []) | index($alias)) | .id' <<<"${deployments_json}" | head -n 1)"
  fi

  if [[ -z "${production_id}" ]]; then
    echo "Unable to identify the active production deployment for ${project_name}; refusing cleanup." >&2
    exit 1
  fi

  local deleted_count=0
  while true; do
    deployments_json="$(get_deployments "${project_name}")"
    mapfile -t deployment_ids < <(jq -r '.result[]?.id // empty' <<<"${deployments_json}")
    [[ "${#deployment_ids[@]}" -eq 0 ]] && break

    local deleted_this_round=0
    for deployment_id in "${deployment_ids[@]}"; do
      [[ "${deployment_id}" == "${production_id}" ]] && continue
      if [[ "${dry_run}" == "true" ]]; then
        echo "DRY-RUN: would delete ${project_name} deployment ${deployment_id}"
      else
        api_request DELETE "${API_BASE}/accounts/${CLOUDFLARE_ACCOUNT_ID}/pages/projects/${project_name}/deployments/${deployment_id}?force=true" >/dev/null
        echo "Deleted ${project_name} deployment ${deployment_id}"
      fi
      deleted_count=$((deleted_count + 1))
      deleted_this_round=1
    done

    [[ "${dry_run}" == "true" ]] && break
    if [[ "${deleted_this_round}" -eq 0 ]]; then
      break
    fi
  done

  if [[ "${dry_run}" == "true" ]]; then
    echo "DRY-RUN: ${project_name}: ${deleted_count} deployments would be deleted; production ${production_id} would be retained."
    return 0
  fi

  deployments_json="$(get_deployments "${project_name}")"
  local remaining_count
  remaining_count="$(jq '[.result[]? | select(.id != $id)] | length' --arg id "${production_id}" <<<"${deployments_json}")"
  if [[ "${remaining_count}" != "0" ]]; then
    echo "${project_name} still has ${remaining_count} non-production deployments; refusing project deletion." >&2
    exit 1
  fi

  api_request DELETE "${API_BASE}/accounts/${CLOUDFLARE_ACCOUNT_ID}/pages/projects/${project_name}" >/dev/null
  echo "Deleted Pages project ${project_name}; retained deployment was removed with the project."
}

token_status="$(api_request GET "${API_BASE}/user/tokens/verify")"
token_state="$(jq -r '.result.status // empty' <<<"${token_status}")"
if [[ "${token_state}" != "active" ]]; then
  echo "Cloudflare API token is not active (status: ${token_state:-unknown})" >&2
  exit 1
fi

IFS=',' read -r -a projects <<< "${CLEANUP_PAGES_PROJECTS}"
for project_name in "${projects[@]}"; do
  project_name="${project_name//[[:space:]]/}"
  [[ -n "${project_name}" ]] || continue
  cleanup_project "${project_name}"
done
