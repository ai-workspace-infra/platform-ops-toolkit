#!/usr/bin/env bash
set -euo pipefail

CONFIG_FILE="${CLOUDFLARE_BOUNDARY_CONFIG:?CLOUDFLARE_BOUNDARY_CONFIG is required}"
PORTAL_DIR="${PORTAL_DIR:?PORTAL_DIR is required}"
portal_config="${PORTAL_DIR}/src/config/runtime-service-config.uat.yaml"

test -f "${portal_config}" || { echo "Portal UAT runtime config not found: ${portal_config}" >&2; exit 1; }

console_host="$(jq -er '.spec.serverless.console_host' "${CONFIG_FILE}")"
accounts_host="$(jq -er '.spec.serverless.accounts_host' "${CONFIG_FILE}")"
portal_dashboard="$(awk '$1 == "dashboardUrl:" {print $2}' "${portal_config}")"
portal_auth="$(awk '$1 == "authUrl:" {print $2}' "${portal_config}")"
portal_api="$(awk '$1 == "apiBaseUrl:" {print $2}' "${portal_config}")"

[[ "${portal_dashboard}" == "https://${console_host}" ]] || { echo "Portal dashboardUrl (${portal_dashboard}) differs from GitOps Console (https://${console_host})" >&2; exit 1; }
[[ "${portal_auth}" == "https://${accounts_host}" ]] || { echo "Portal authUrl (${portal_auth}) differs from GitOps Accounts (https://${accounts_host})" >&2; exit 1; }
[[ "${portal_api}" == "https://${accounts_host}/api" ]] || { echo "Portal apiBaseUrl (${portal_api}) differs from GitOps Accounts API (https://${accounts_host}/api)" >&2; exit 1; }

echo "Portal UAT domains match GitOps: Console=${console_host}, Accounts=${accounts_host}"
