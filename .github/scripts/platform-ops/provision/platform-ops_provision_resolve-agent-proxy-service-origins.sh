#!/usr/bin/env bash
set -euo pipefail

: "${AGENT_CONTROLLER_URL:?AGENT_CONTROLLER_URL is required}"
: "${GITHUB_OUTPUT:?GITHUB_OUTPUT is required}"

accounts_service_base_url="${AGENT_CONTROLLER_URL%/}"
billing_service_base_url="${BILLING_SERVICE_BASE_URL:-}"

if [[ "${AGENT_CONTROLLER_URL}" == https://accounts-serverless-* ]]; then
  topology_file="${GITOPS_SERVERLESS_ROUTING_YAML:?GITOPS_SERVERLESS_ROUTING_YAML is required for a serverless Accounts controller}"
  test -f "${topology_file}" || {
    echo "::error::GitOps serverless routing declaration not found: ${topology_file}" >&2
    exit 1
  }
  command -v ruby >/dev/null 2>&1 || {
    echo "::error::Ruby is required to resolve Agent Proxy service origins" >&2
    exit 1
  }

  service_origins="$({
    ruby -ryaml -e '
      document = YAML.safe_load(File.read(ARGV.fetch(0)), permitted_classes: [], permitted_symbols: [], aliases: false)
      abort("GitOps routing declaration must be EdgeRoutingConfig") unless document.is_a?(Hash) && document["kind"] == "EdgeRoutingConfig"
      cloud_run = document.dig("spec", "serverless", "cloud_run")
      abort("GitOps routing declaration must define spec.serverless.cloud_run") unless cloud_run.is_a?(Hash)
      puts cloud_run.fetch("accounts")
      puts cloud_run.fetch("billing_service")
    ' "${topology_file}"
  })"
  accounts_service_base_url="$(printf '%s\n' "${service_origins}" | sed -n '1p')"
  billing_service_base_url="$(printf '%s\n' "${service_origins}" | sed -n '2p')"
fi

for entry in \
  "accounts_service_base_url=${accounts_service_base_url}" \
  "billing_service_base_url=${billing_service_base_url}"; do
  key="${entry%%=*}"
  value="${entry#*=}"
  if [[ ! "${value}" =~ ^https://[^/]+$ ]]; then
    echo "::error::${key} must be an HTTPS origin without a path: ${value:-<empty>}" >&2
    exit 1
  fi
  echo "${key}=${value}" >> "${GITHUB_OUTPUT}"
done

if [[ "${AGENT_CONTROLLER_URL}" == https://accounts-serverless-* ]]; then
  echo "Resolved token-protected Agent Proxy machine APIs from GitOps Cloud Run origins."
else
  echo "Agent Proxy machine APIs follow the selected selfhost service origins."
fi
