#!/usr/bin/env bash
set -euo pipefail

# Canonical DNS names are user-facing aliases. SSH migration must use the
# mode-qualified selfhost endpoint declared by GitOps instead of deriving a
# hostname from the canonical alias.

config_file="${GITOPS_ROUTING_CONFIG:?GITOPS_ROUTING_CONFIG must point to the rendered GitOps manifest}"
output_file="${GITHUB_OUTPUT:?GITHUB_OUTPUT is required}"
service="${MIGRATION_SERVICE:-console}"

if [[ ! -s "${config_file}" ]]; then
  echo "::error::GitOps routing manifest not found or empty: ${config_file}" >&2
  exit 1
fi
command -v jq >/dev/null 2>&1 || {
  echo "::error::jq is required to resolve the GitOps migration target" >&2
  exit 1
}

if [[ "$(jq -r '.kind // empty' "${config_file}")" != "EdgeRoutingConfig" ||
      "$(jq -r '.metadata.mode // empty' "${config_file}")" != "selfhost" ||
      "$(jq -r '.spec.runtime.mode // empty' "${config_file}")" != "selfhost" ]]; then
  echo "::error::Accounts SSH migration requires a selfhost EdgeRoutingConfig." >&2
  exit 1
fi

target_host="$(jq -er --arg service "${service}" '.spec.public_endpoints[$service].host // empty' "${config_file}")"
if [[ ! "${target_host}" =~ ^[a-z0-9][a-z0-9.-]*$ ||
      "${target_host}" != "${service}-selfhost-"* ]]; then
  echo "::error::GitOps public_endpoints.${service}.host is not a valid selfhost SSH target: ${target_host}" >&2
  exit 1
fi

printf 'target_host=%s\n' "${target_host}" >>"${output_file}"
echo "Resolved ${service} SSH migration target from GitOps: ${target_host}"
