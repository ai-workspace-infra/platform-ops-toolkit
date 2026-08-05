#!/bin/bash
set -euo pipefail

# Build the migratectl binary from the checked-out accounts service.
#
# The same binary is used for both export (PROD) and import (UAT): the snapshot
# embeds a schemaHash derived from the binary's own schema.sql, and import
# refuses a snapshot whose hash does not match. Two binaries built from
# different accounts refs would fail that check.

ACCOUNTS_DIR="${ACCOUNTS_DIR:-accounts}"
OUTPUT="${OUTPUT:-${GITHUB_WORKSPACE:-$PWD}/bin/migratectl}"

if [ ! -d "${ACCOUNTS_DIR}/cmd/migratectl" ]; then
  echo "ERROR: ${ACCOUNTS_DIR}/cmd/migratectl not found -- is the accounts repository checked out?" >&2
  exit 1
fi

mkdir -p "$(dirname "${OUTPUT}")"
(cd "${ACCOUNTS_DIR}" && go build -o "${OUTPUT}" ./cmd/migratectl)

"${OUTPUT}" --help >/dev/null
echo "migratectl built at ${OUTPUT}"
