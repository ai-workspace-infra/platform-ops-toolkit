#!/usr/bin/env bash
set -euo pipefail
umask 077

die() { echo "::error::$*" >&2; exit 1; }
for name in ACTIONS_ID_TOKEN_REQUEST_URL ACTIONS_ID_TOKEN_REQUEST_TOKEN VAULT_ADDR VAULT_ROLE ZERO_SERVICE_TOKEN NETWORK_REQUEST_FILE NETWORK_ID ACCOUNTS_API_URL INVITATION_TTL_MINUTES GITHUB_RUN_ID GITHUB_RUN_ATTEMPT; do
  [[ -n "${!name:-}" ]] || die "$name is required"
done
[[ "$NETWORK_ID" =~ ^net_[a-zA-Z0-9][a-zA-Z0-9_-]{1,62}$ ]] || die 'NETWORK_ID is invalid'
[[ "$INVITATION_TTL_MINUTES" =~ ^([5-9]|[12][0-9]|30)$ ]] || die 'INVITATION_TTL_MINUTES must be between 5 and 30'
[[ "$GITHUB_RUN_ID" =~ ^[0-9]+$ && "$GITHUB_RUN_ATTEMPT" =~ ^[0-9]+$ ]] || die 'GitHub run identity is invalid'
request_file="$NETWORK_REQUEST_FILE"
[[ -s "$request_file" ]] || die 'validated private network request is missing'

temp_dir="$(mktemp -d "${RUNNER_TEMP:-/tmp}/xconnect-network.XXXXXX")"
trap 'rm -rf "$temp_dir"' EXIT
chmod 700 "$temp_dir"
response_file="$temp_dir/zero-response.json"
vault_response="$temp_dir/vault-login.json"
vault_write_body="$temp_dir/vault-write.json"

# Obtain the short-lived OIDC JWT from GitHub Actions; github.token is a GitHub
# API token and is deliberately not accepted as a Vault JWT.
oidc_url="${ACTIONS_ID_TOKEN_REQUEST_URL}&audience=vault"
oidc_response="$(curl --fail --silent --show-error \
  -H "Authorization: Bearer ${ACTIONS_ID_TOKEN_REQUEST_TOKEN}" "$oidc_url")" || die 'GitHub OIDC token request failed'
jwt="$(jq -er '.value | strings | select(length > 0)' <<<"$oidc_response")" || die 'GitHub OIDC response did not contain a token'
unset oidc_response
echo "::add-mask::${jwt}"

jq -n --arg role "$VAULT_ROLE" --arg jwt "$jwt" '{role:$role,jwt:$jwt}' > "$temp_dir/vault-login-body.json"
unset jwt
vault_status="$(curl --silent --show-error --output "$vault_response" --write-out '%{http_code}' \
  -H 'Content-Type: application/json' --data-binary "@$temp_dir/vault-login-body.json" \
  "${VAULT_ADDR%/}/v1/auth/jwt/login" || true)"
[[ "$vault_status" == 200 ]] || die "Vault JWT login failed (HTTP ${vault_status})"
vault_token="$(jq -er '.auth.client_token | strings | select(length > 0)' "$vault_response")" || die 'Vault JWT login did not return a client token'
unset vault_response
echo "::add-mask::${vault_token}"

expires_at="$(python3 -c 'from datetime import datetime,timezone,timedelta; import sys; print((datetime.now(timezone.utc)+timedelta(minutes=int(sys.argv[1]))).isoformat(timespec="seconds").replace("+00:00","Z"))' "$INVITATION_TTL_MINUTES")"
jq --arg owner "$(jq -er '.owner_email' "$NETWORK_REQUEST_FILE")" --arg expires "$expires_at" \
  '.owner_email=$owner | .bootstrap.invite.expires_at=$expires | del(.bootstrap.invite.ttl_minutes)' \
  "$request_file" > "$temp_dir/zero-request.json" || die 'Could not finalize network bootstrap request'
status="$(curl --silent --show-error --output "$response_file" --write-out '%{http_code}' \
  -H "X-Service-Token: ${ZERO_SERVICE_TOKEN}" -H 'Content-Type: application/json' \
  --data-binary "@$temp_dir/zero-request.json" \
  "${ACCOUNTS_API_URL%/}/api/internal/overlay/networks/bootstrap" || true)"
[[ "$status" == 201 ]] || die "XConnect Zero network bootstrap failed (HTTP ${status}); no invitation was written to Vault"
jq -e --arg network "$NETWORK_ID" --arg device "$(jq -r '.bootstrap.invite.device_id' "$temp_dir/zero-request.json")" \
  '.network.id == $network and .invite.network_id == $network and .invite.device_id == $device and .invite.role == "gateway" and .invite.platform == "linux" and .invite.remaining_uses == 1 and (.join_uri | strings | startswith("xconnect://join/"))' \
  "$response_file" >/dev/null || die 'XConnect Zero response does not match the requested network/Gateway invitation'

jq -n --arg network "$NETWORK_ID" --arg gateway "$(jq -r '.bootstrap.network.gateway_id' "$temp_dir/zero-request.json")" \
  --arg join_uri "$(jq -er '.join_uri' "$response_file")" \
  '{data:{NETWORK_ID:$network,GATEWAY_ID:$gateway,JOIN_URI:$join_uri}}' > "$vault_write_body"
invite_path="CICD/shared/xconnect-operator-invite/${NETWORK_ID}-${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT}"
write_status="$(curl --silent --show-error --output "$temp_dir/vault-write-response.json" --write-out '%{http_code}' \
  -H "X-Vault-Token: ${vault_token}" -H 'Content-Type: application/json' \
  --request POST --data-binary "@$vault_write_body" \
  "${VAULT_ADDR%/}/v1/kv/data/${invite_path}" || true)"
[[ "$write_status" == 200 || "$write_status" == 204 ]] || die "Vault invite write failed (HTTP ${write_status}); do not retry blindly because the Zero API may have already created the network and invite"

unset vault_token ZERO_SERVICE_TOKEN ZERO_OWNER_EMAIL
summary="Created XConnect network ${NETWORK_ID}; one-use Gateway invitation stored at kv/${invite_path}. CI cannot read it back."
echo "$summary"
if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then printf '%s\n' "$summary" >> "$GITHUB_STEP_SUMMARY"; fi
