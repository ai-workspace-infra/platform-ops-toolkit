#!/usr/bin/env bash
set -euo pipefail

# -----------------------------------------------------------------------------
# GitHub Actions UAT Daily Cleanup Runner
# -----------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../scripts/serverless_uat" && pwd)"

echo "==> [CI Runner] Running UAT Daily Teardown..."

export VAULT_ADDR="${VAULT_ADDR:-https://vault.svc.plus}"

"${SCRIPT_DIR}/destroy_ephemeral_compute.sh"

echo "==> [CI Runner] UAT Daily Teardown completed."
