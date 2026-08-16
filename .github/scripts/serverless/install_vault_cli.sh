#!/usr/bin/env bash
set -euo pipefail

VAULT_VERSION="${VAULT_VERSION:-1.21.3}"
VAULT_ARCHIVE="vault_${VAULT_VERSION}_linux_amd64.zip"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

wget -qO "${TMP_DIR}/${VAULT_ARCHIVE}" \
  "https://releases.hashicorp.com/vault/${VAULT_VERSION}/${VAULT_ARCHIVE}"
unzip -qo "${TMP_DIR}/${VAULT_ARCHIVE}" -d "${TMP_DIR}"
sudo install -m 0755 "${TMP_DIR}/vault" /usr/local/bin/vault
vault version
