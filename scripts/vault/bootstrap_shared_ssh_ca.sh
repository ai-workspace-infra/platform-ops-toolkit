#!/usr/bin/env bash
set -euo pipefail

# Prepare Vault's SSH CA used by the migration pipeline to reach the existing
# vault.svc.plus node with 30-minute user certificates.
#
#   --check  (default) read-only: mount, CA and role exist as declared
#   --apply  create the mount/role if missing; never regenerates an existing CA
#   --print-ca  print the CA public key to install on the existing node
#
# On the existing node an operator installs the printed key once:
#   /etc/ssh/vault-user-ca.pub  and in sshd_config:
#     TrustedUserCAKeys /etc/ssh/vault-user-ca.pub
#     AuthorizedPrincipalsFile /etc/ssh/auth_principals/%u
#   with /etc/ssh/auth_principals/<ssh_user> containing only <ssh_user>.

mount=ssh-client-signer
role=vault-legacy-ops
principal="${VAULT_LEGACY_SSH_USER:-vault-migrate}"
mode=check

while (($#)); do
  case "$1" in
    --check) mode=check ;;
    --apply) mode=apply ;;
    --print-ca) mode=print ;;
    -h|--help) sed -n '4,17p' "$0"; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done
[[ "${principal}" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || { echo "invalid VAULT_LEGACY_SSH_USER" >&2; exit 1; }
for command_name in vault jq; do
  command -v "${command_name}" >/dev/null 2>&1 || { echo "${command_name} is required" >&2; exit 1; }
done
export VAULT_ADDR="${VAULT_ADDR:-https://vault.svc.plus}"

role_body() {
  jq -n --arg principal "${principal}" '{
    key_type: "ca",
    allow_user_certificates: true,
    allowed_users: $principal,
    default_user: $principal,
    allowed_extensions: "",
    default_extensions: {},
    ttl: "30m",
    max_ttl: "30m",
    algorithm_signer: "default"
  }'
}

mounted() { vault secrets list -format=json | jq -e --arg m "${mount}/" 'has($m)' >/dev/null; }
has_ca() { vault read -field=public_key "${mount}/config/ca" >/dev/null 2>&1; }

case "${mode}" in
  print)
    vault read -field=public_key "${mount}/config/ca"
    ;;
  apply)
    mounted || vault secrets enable -path="${mount}" ssh
    has_ca || vault write "${mount}/config/ca" generate_signing_key=true key_type=ed25519 >/dev/null
    role_body | vault write "${mount}/roles/${role}" - >/dev/null
    echo "SSH CA ${mount} and role ${role} (principal ${principal}, 30m) are in place"
    ;;
  check)
    mounted || { echo "${mount} is not mounted; run --apply" >&2; exit 1; }
    has_ca || { echo "${mount} has no CA; run --apply" >&2; exit 1; }
    vault read -format=json "${mount}/roles/${role}" |
      jq -e --arg principal "${principal}" \
        '.data.allowed_users == $principal and .data.max_ttl == 1800 and .data.allow_user_certificates == true' >/dev/null || {
        echo "${mount}/roles/${role} differs from the declaration; run --apply" >&2
        exit 1
      }
    echo "SSH CA check: OK"
    ;;
esac
