#!/usr/bin/env bash
# Run on the legacy host as root; pass the public CA on stdin. No private key.
set -euo pipefail
[[ $(id -u) == 0 ]] || { echo 'Run as root' >&2; exit 1; }
principal=${VAULT_LEGACY_SSH_USER:-vault-migrate}
[[ $principal =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || exit 1
IFS= read -r ca
[[ $ca == ssh-ed25519\ * ]] || { echo 'Expected an Ed25519 public CA' >&2; exit 1; }
tmp=$(mktemp -d)
trap 'rm -f "$tmp/ca" "$tmp/config" "$tmp/sudo"; rmdir "$tmp"' EXIT
printf '%s\n' "$ca" > "$tmp/ca"
ssh-keygen -lf "$tmp/ca" >/dev/null
id "$principal" >/dev/null 2>&1 || useradd --create-home --shell /bin/bash "$principal"
install -d -m 755 /etc/ssh/auth_principals
install -m 644 "$tmp/ca" /etc/ssh/vault-user-ca.pub
printf '%s\n' "$principal" > "/etc/ssh/auth_principals/$principal"
chmod 644 "/etc/ssh/auth_principals/$principal"
printf '%s ALL=(ALL) NOPASSWD: ALL\n' "$principal" > "$tmp/sudo"
visudo -cf "$tmp/sudo" >/dev/null
install -m 440 "$tmp/sudo" "/etc/sudoers.d/vault-migration-$principal"
printf 'TrustedUserCAKeys /etc/ssh/vault-user-ca.pub\nAuthorizedPrincipalsFile /etc/ssh/auth_principals/%%u\n' > "$tmp/config"
target=/etc/ssh/sshd_config.d/20-vault-migration-ca.conf
[[ ! -e $target ]] || cmp -s "$tmp/config" "$target" || { echo 'Existing CA SSH configuration differs; review it first' >&2; exit 1; }
install -m 644 "$tmp/config" "$target"
if ! sshd -t; then
  rm -f "$target"
  echo 'SSH configuration rejected; service was not reloaded' >&2
  exit 1
fi
systemctl reload ssh
echo 'Legacy SSH CA configured; existing key access retained'
