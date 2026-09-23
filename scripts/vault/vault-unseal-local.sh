#!/usr/bin/env bash
set -euo pipefail
set +x
umask 077

usage() {
  cat <<'EOF'
Usage: vault-unseal-local.sh [--addr http://127.0.0.1:8200]

Interactively submit exactly one Vault Shamir unseal share to the local Vault
API. Repeat on the same node until Vault reports sealed=false. Run separately
on every node that needs unsealing.

The script does not accept tokens, read key files, persist input, or contact a
non-loopback address. It must be run from a shell on the Vault host (for
example, an SSH session established through IAP or the approved XConnect).
EOF
}

vault_addr="http://127.0.0.1:8200"
while (($#)); do
  case "$1" in
    --addr)
      [[ $# -ge 2 ]] || { usage >&2; exit 2; }
      vault_addr="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      exit 2
      ;;
  esac
done

case "$vault_addr" in
  http://127.0.0.1:8200|http://localhost:8200|http://\[::1\]:8200) ;;
  *)
    echo "Refusing non-loopback Vault address: $vault_addr" >&2
    exit 2
    ;;
esac

command -v curl >/dev/null 2>&1 || { echo "curl is required" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "jq is required" >&2; exit 1; }

health="$(curl --silent --show-error --fail \
  "$vault_addr/v1/sys/health?standbyok=true&sealedcode=200&uninitcode=200")" || {
  echo "Vault health endpoint is unreachable at $vault_addr" >&2
  exit 1
}

initialized="$(jq -r '.initialized // false' <<<"$health")"
sealed="$(jq -r '.sealed // true' <<<"$health")"
if [[ "$initialized" != true ]]; then
  echo "Vault is not initialized; refusing unseal. Do not run operator init during a Raft migration." >&2
  exit 1
fi
if [[ "$sealed" != true ]]; then
  echo "Vault is already unsealed; no key was requested."
  exit 0
fi

seal_status="$(curl --silent --show-error --fail "$vault_addr/v1/sys/seal-status")" || {
  echo "Vault seal-status endpoint is unreachable at $vault_addr" >&2
  exit 1
}
progress="$(jq -r '.progress // 0' <<<"$seal_status")"
threshold="$(jq -r '.t // .threshold // 0' <<<"$seal_status")"
if [[ ! "$progress" =~ ^[0-9]+$ || ! "$threshold" =~ ^[1-9][0-9]*$ ]]; then
  echo "Vault returned invalid unseal progress/threshold; refusing to request a share." >&2
  exit 1
fi
printf 'Vault is sealed. Current unseal progress: %s/%s\n' "$progress" "$threshold"
IFS= read -r -s -p 'Enter one unseal share (input hidden): ' unseal_share
printf '\n'
if [[ -z "$unseal_share" || ! "$unseal_share" =~ ^[A-Za-z0-9+/=_-]+$ ]]; then
  unset unseal_share
  echo "Empty or malformed share; no request was sent." >&2
  exit 2
fi

# Vault Shamir shares use a base64-compatible alphabet. The value travels only
# through this process pipe into curl's stdin; it is not placed in argv, env,
# shell history, a temporary file, or workflow logs.
response="$(printf '{"key":"%s"}' "$unseal_share" | curl --silent --show-error \
  --request PUT \
  --header 'Content-Type: application/json' \
  --data-binary @- \
  "$vault_addr/v1/sys/unseal")"
unset unseal_share

jq -e 'type == "object" and has("sealed") and has("progress")' \
  <<<"$response" >/dev/null || {
  echo "Vault returned an unexpected response; inspect Vault health locally. No key was saved." >&2
  exit 1
}

jq -r '"Result: sealed=\(.sealed), progress=\(.progress), threshold=\(.t // .threshold // "unknown")"' \
  <<<"$response"
if [[ "$(jq -r '.sealed' <<<"$response")" == false ]]; then
  echo "This node is unsealed. Do not submit further shares to this node."
else
  echo "Repeat the script with the next authorized share on this node, then repeat for each other node."
fi
