#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
workflow="${repo_root}/.github/workflows/data-migration.yaml"
script="${repo_root}/.github/scripts/data-migration/supabase_metadata_migration.sh"

python3 - "${workflow}" <<'PY'
from pathlib import Path
import sys

import yaml

document = yaml.safe_load(Path(sys.argv[1]).read_text(encoding="utf-8"))
triggers = document.get("on", document.get(True))
for event in ("workflow_call", "workflow_dispatch"):
    inputs = triggers[event]["inputs"]
    for removed in ("supabase_source_transport", "supabase_source_tunnel_sni", "supabase_source_dsn_key", "supabase_source_ssh_target_port"):
        if removed in inputs:
            raise SystemExit(f"{event} must not expose removed {removed} input")

job = document["jobs"]["supabase_metadata_migration"]
if "SUPABASE_SOURCE_TRANSPORT" in job["env"]:
    raise SystemExit("Supabase migration must not configure a removable source transport")
steps = {step.get("name"): step for step in job["steps"]}
if "Install PostgreSQL source tunnel client" in steps:
    raise SystemExit("Supabase migration must not install the removed stunnel client")
if "MIGRATION_SOURCE_SSH_PRIVATE_KEY_B64" not in steps["Load Supabase target DSN and source SSH key from Vault"]["with"]["secrets"]:
    raise SystemExit("Supabase migration must load the dedicated PROD source SSH key from Vault")
if "MIGRATION_SOURCE_DSN" in steps["Load Supabase target DSN and source SSH key from Vault"]["with"]["secrets"]:
    raise SystemExit("Supabase migration must not load the obsolete source password DSN")
if steps["Configure source tunnel SSH"]["with"].get("ssh_key_b64") != "${{ steps.vault.outputs.MIGRATION_SOURCE_SSH_PRIVATE_KEY_B64 }}":
    raise SystemExit("Supabase migration must configure SSH with the dedicated source key")
PY

if rg -n 'stunnel|SUPABASE_SOURCE_TRANSPORT|SUPABASE_SOURCE_TUNNEL_SNI' "${script}"; then
  echo "SSH-only Supabase migration script still contains a removed source transport" >&2
  exit 1
fi

if rg -n 'MIGRATION_SOURCE_DSN|SOURCE_SSH_TARGET_PORT|SOURCE_TUNNEL_LOCAL_PORT|pg_dump "\$\{SOURCE_DSN\}"' "${script}"; then
  echo "Supabase migration must not authenticate to the source through a runner-side DSN." >&2
  exit 1
fi
grep -Fq 'docker exec "${SOURCE_CONTAINER}" pg_dump' "${script}"
grep -Fq 'SOURCE_DB_USER="${SUPABASE_SOURCE_DB_USER:-readonly}"' "${script}"

grep -Fq 'SOURCE_SSH_KEY_PATH="${SUPABASE_SOURCE_SSH_KEY_PATH:-${HOME}/.ssh/id_deploy}"' "${script}"
grep -Fq '  -o IdentitiesOnly=yes' "${script}"
grep -Fq '  -i "${SOURCE_SSH_KEY_PATH}"' "${script}"

echo "supabase_migration_ssh_only_contract_test: PASS"
