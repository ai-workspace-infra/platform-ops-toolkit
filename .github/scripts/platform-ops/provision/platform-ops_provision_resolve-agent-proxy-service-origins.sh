#!/usr/bin/env bash
set -euo pipefail

: "${AGENT_CONTROLLER_URL:?AGENT_CONTROLLER_URL is required}"
: "${GITHUB_OUTPUT:?GITHUB_OUTPUT is required}"
: "${DEPLOYMENT_ENV:?DEPLOYMENT_ENV is required}"

topology_file="${GITOPS_SERVERLESS_ROUTING_YAML:?GITOPS_SERVERLESS_ROUTING_YAML is required}"
test -f "${topology_file}" || {
  echo "::error::GitOps routing declaration not found: ${topology_file}" >&2
  exit 1
}
command -v ruby >/dev/null 2>&1 || { echo "::error::Ruby is required" >&2; exit 1; }

# The selected topology is the authority for machine origins. Public hostnames
# are an environment contract; they do not encode whether the API is selfhost
# or serverless. Never route an agent through a browser challenge or infer the
# Billing upstream by replacing part of the Accounts URL.
service_origins="$(ruby -ryaml -ruri -e '
  document = YAML.safe_load(File.read(ARGV.fetch(0)), permitted_classes: [], permitted_symbols: [], aliases: false)
  environment, controller, billing = ARGV[1..3]
  abort("GitOps declaration must be EdgeRoutingConfig") unless document.is_a?(Hash) && document["kind"] == "EdgeRoutingConfig"
  abort("GitOps service origins belong to another environment") unless document.dig("metadata", "environment") == environment
  canonical_accounts = environment == "prod" ? "https://accounts.svc.plus" : "https://accounts-#{environment}.onwalk.net"
  canonical_billing = environment == "prod" ? "https://billing.svc.plus" : "https://billing-#{environment}.onwalk.net"
  serverless = document.dig("spec", "serverless") || {}
  selfhost = document.dig("spec", "domains", URI(canonical_accounts).host, "selfhost")
  if controller == canonical_accounts || controller == "https://#{serverless["accounts_host"]}"
    cloud_run = serverless.fetch("cloud_run")
    origins = [cloud_run.fetch("accounts"), cloud_run.fetch("billing_service")]
    origins.each do |origin|
      uri = URI(origin)
      abort("Machine origin must be the selected environment Cloud Run service") unless uri.scheme == "https" && uri.host&.start_with?("#{environment}-") && uri.host.end_with?(".run.app") && uri.path.empty? && !uri.userinfo && !uri.query && !uri.fragment
    end
  elsif selfhost && controller == "https://#{selfhost}"
    abort("Billing public contract belongs to another environment") unless billing == canonical_billing
    # Selfhost remains an explicit override; both hosts come from topology.
    selfhost_billing = document.dig("spec", "domains", URI(canonical_billing).host, "selfhost")
    abort("GitOps must declare the selfhost Billing origin") unless selfhost_billing
    origins = [controller, "https://#{selfhost_billing}"]
  else
    abort("Agent controller does not match the selected environment topology")
  end
  puts origins
' "${topology_file}" "${DEPLOYMENT_ENV}" "${AGENT_CONTROLLER_URL%/}" "${BILLING_SERVICE_BASE_URL:-}")"

accounts_service_base_url="$(printf '%s\n' "${service_origins}" | sed -n '1p')"
billing_service_base_url="$(printf '%s\n' "${service_origins}" | sed -n '2p')"
for entry in "accounts_service_base_url=${accounts_service_base_url}" "billing_service_base_url=${billing_service_base_url}"; do
  key="${entry%%=*}"
  value="${entry#*=}"
  if [[ ! "${value}" =~ ^https://[^/]+$ ]]; then
    echo "::error::${key} must be an HTTPS origin without a path" >&2
    exit 1
  fi
  echo "${entry}" >> "${GITHUB_OUTPUT}"
done
echo "Resolved environment-scoped Agent Proxy machine origins from GitOps."
