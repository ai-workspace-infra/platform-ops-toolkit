#!/usr/bin/env bash
set -euo pipefail

manifest="${AI_AGGREGATOR_MANIFEST:-gitops/topology/uat/selfhost/ai-aggregator.yaml}"
domain="$(python3 - "$manifest" <<'PY'
import sys, yaml
data = yaml.safe_load(open(sys.argv[1], encoding="utf-8"))
print(data["spec"]["entrypoint"]["domain"])
PY
)"
direct_domain="$(python3 - "$manifest" <<'PY'
import sys, yaml
data = yaml.safe_load(open(sys.argv[1], encoding="utf-8"))
print(data["spec"]["entrypoint"]["direct_api_domain"])
PY
)"

request_status() {
  local url="$1"
  shift
  curl --silent --show-error --output /dev/null --write-out '%{http_code}' "$@" "$url"
}

# A no-token request must be rejected by the gateway/application. This avoids
# putting a client token in the repository or in CI arguments. The optional
# token is supplied by the protected runner environment for a real smoke test.
main_status="$(request_status "https://${domain}/v1/models")"
direct_status="$(request_status "https://${direct_domain}/v1/models")"
[[ "$main_status" == 401 || "$main_status" == 403 ]] || {
  echo "New API accepted an unauthenticated request: ${main_status}" >&2; exit 1;
}
[[ "$direct_status" == 401 || "$direct_status" == 403 ]] || {
  echo "LiteLLM accepted an unauthenticated request: ${direct_status}" >&2; exit 1;
}

if [[ -n "${AI_AGGREGATOR_CLIENT_TOKEN:-}" ]]; then
  authenticated_args=(-H "Authorization: Bearer ${AI_AGGREGATOR_CLIENT_TOKEN}")
  main_auth_status="$(request_status "https://${domain}/v1/models" "${authenticated_args[@]}")"
  direct_auth_status="$(request_status "https://${direct_domain}/v1/models" "${authenticated_args[@]}")"
  [[ "$main_auth_status" =~ ^2[0-9][0-9]$ ]] || { echo "New API token smoke test failed: ${main_auth_status}" >&2; exit 1; }
  [[ "$direct_auth_status" =~ ^2[0-9][0-9]$ ]] || { echo "LiteLLM token smoke test failed: ${direct_auth_status}" >&2; exit 1; }
fi

echo "gateway authentication checks passed for ${domain} and ${direct_domain}"
