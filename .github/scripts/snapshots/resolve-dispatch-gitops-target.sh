#!/usr/bin/env bash
set -euo pipefail

config_file="${GITOPS_TOPOLOGY_FILE:?GITOPS_TOPOLOGY_FILE is required}"
expected_environment="${EXPECTED_ENVIRONMENT:?EXPECTED_ENVIRONMENT is required}"
expected_mode="${EXPECTED_MODE:?EXPECTED_MODE is required}"

[[ -s "${config_file}" ]] || {
  echo "::error::GitOps topology is missing or empty: ${config_file}" >&2
  exit 1
}

readarray -t values < <(CONFIG_FILE="${config_file}" ruby -ryaml -e '
  document = YAML.safe_load(File.read(ENV.fetch("CONFIG_FILE")), aliases: false)
  metadata = document.fetch("metadata")
  runtime = document.fetch("spec").fetch("runtime")
  serverless = document.fetch("spec").fetch("serverless")
  environment = metadata.fetch("environment")
  mode = runtime.fetch("mode")
  zone = document.fetch("spec").fetch("cloudflare").fetch("zone_name")
  accounts = serverless.fetch("accounts_host")
  abort("invalid target domain") unless zone.match?(/\A[a-z0-9.-]+\z/)
  accounts = "https://#{accounts}" unless accounts.start_with?("https://")
  abort("invalid Accounts controller") unless accounts.match?(/\Ahttps:\/\/[a-z0-9.-]+\z/)
  puts environment
  puts mode
  puts zone
  puts accounts
')

[[ "${values[0]:-}" == "${expected_environment}" ]] || {
  echo "::error::GitOps topology environment does not match selected environment." >&2
  exit 1
}
[[ "${values[1]:-}" == "${expected_mode}" ]] || {
  echo "::error::GitOps runtime mode does not match selected dispatch mode." >&2
  exit 1
}

{
  printf 'target_domain_base=%s\n' "${values[2]}"
  printf 'agent_controller_url=%s\n' "${values[3]}"
} >> "${GITHUB_OUTPUT:?GITHUB_OUTPUT is required}"

echo "Resolved ${expected_environment}/${expected_mode} dispatch target from GitOps: ${values[2]}"
