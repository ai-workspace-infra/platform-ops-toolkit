#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"

python3 - "${repo_root}" <<'PY'
from pathlib import Path
import sys

import yaml

root = Path(sys.argv[1])

def load(path):
    document = yaml.safe_load(path.read_text(encoding="utf-8"))
    return document, document.get("on", document.get(True))

serverless, _ = load(root / ".github/workflows/serverless-orchestrator.yml")
selfhost, _ = load(root / ".github/workflows/selfhost-orchestrator.yml")
migration, _ = load(root / ".github/workflows/data-migration.yaml")

serverless_group = serverless["jobs"]["serverless_domains"]["concurrency"]["group"]
selfhost_group = selfhost["jobs"]["switch_dns"]["concurrency"]["group"]
if serverless_group != "public-dns-${{ inputs.vault_env_path || 'uat' }}":
    raise SystemExit(f"unexpected serverless public DNS group: {serverless_group!r}")
if selfhost_group != "public-dns-${{ needs.provision.outputs.deployment_env }}":
    raise SystemExit(f"unexpected selfhost public DNS group: {selfhost_group!r}")

migration_group = migration["concurrency"]["group"]
if migration_group != "data-migration-${{ inputs.vault_env_path || 'sit' }}-${{ inputs.migration_scope || 'accounts' }}":
    raise SystemExit(f"unexpected data migration group: {migration_group!r}")
PY

echo "public_state_concurrency_contract_test: PASS"
