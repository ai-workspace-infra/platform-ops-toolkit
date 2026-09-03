#!/usr/bin/env bash
set -euo pipefail

: "${SSH_PRIVATE_DEPLOY_KEY_B64:?SSH_PRIVATE_DEPLOY_KEY_B64 is required}"
: "${GITHUB_ENV:?GITHUB_ENV is required}"

private_key="$(mktemp)"
trap 'rm -f "${private_key}"' EXIT

if ! printf '%s' "${SSH_PRIVATE_DEPLOY_KEY_B64}" | base64 --decode > "${private_key}"; then
  echo "::error::Vault SSH_PRIVATE_DEPLOY_KEY_B64 is not valid base64." >&2
  exit 1
fi
chmod 600 "${private_key}"

public_key="$(ssh-keygen -y -f "${private_key}" 2>/dev/null)" || {
  echo "::error::Vault SSH_PRIVATE_DEPLOY_KEY_B64 is not a valid SSH private key." >&2
  exit 1
}
[[ -n "${public_key}" ]] || {
  echo "::error::Could not derive an EC2 public key from the Vault deploy key." >&2
  exit 1
}

printf 'SSH_PUBLIC_DEPLOY_KEY=%s\n' "${public_key}" >> "${GITHUB_ENV}"
echo "Derived the AWS EC2 public key from the Vault-managed deploy key."
