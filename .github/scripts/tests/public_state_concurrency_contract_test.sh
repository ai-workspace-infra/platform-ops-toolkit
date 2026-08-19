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
hybrid, _ = load(root / ".github/workflows/hybrid-orchestrator.yml")

serverless_group = serverless["jobs"]["serverless_domains"]["concurrency"]["group"]
selfhost_group = selfhost["jobs"]["switch_dns"]["concurrency"]["group"]
if serverless_group != "public-dns-${{ inputs.vault_env_path || 'uat' }}":
    raise SystemExit(f"unexpected serverless public DNS group: {serverless_group!r}")
if selfhost_group != "public-dns-${{ needs.provision.outputs.deployment_env }}":
    raise SystemExit(f"unexpected selfhost public DNS group: {selfhost_group!r}")

migration_group = migration["concurrency"]["group"]
if migration_group != "data-migration-${{ inputs.vault_env_path || 'sit' }}-${{ inputs.migration_scope || 'accounts' }}":
    raise SystemExit(f"unexpected data migration group: {migration_group!r}")

# The serverless and hybrid orchestrators deploy the same three edge-gateway
# Worker names on the same routes and differ only in the vars they set, so the
# two must never write the same boundary concurrently. The group must carry the
# matrix boundary: a group shared by all three legs makes GitHub cancel the
# queued legs instead of serialising them.
expected_gateway_group = "edge-gateway-${{ inputs.vault_env_path || 'uat' }}-${{ matrix.boundary }}"
for name, workflow in (("serverless", serverless), ("hybrid", hybrid)):
    group = workflow["jobs"]["edge_gateway"].get("concurrency", {}).get("group")
    if group != expected_gateway_group:
        raise SystemExit(f"unexpected {name} edge-gateway group: {group!r}")

# Hybrid is a routing policy, not a deployment target: it must never build an
# artifact or mutate public DNS. Those belong to serverless- and
# selfhost-orchestrator, which already serialise against each other.
for job_name, job in hybrid["jobs"].items():
    steps = job.get("steps", [])
    for step in steps:
        run = step.get("run", "")
        uses = step.get("uses", "")
        if "google-github-actions" in uses or "gcloud" in run:
            raise SystemExit(f"hybrid job {job_name} must not deploy Cloud Run artifacts")
        if "reconcile_cloudflare_domains" in run or "dns" in run.lower():
            raise SystemExit(f"hybrid job {job_name} must not mutate public DNS")
PY

echo "public_state_concurrency_contract_test: PASS"
