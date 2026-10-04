#!/usr/bin/env bash
set -euo pipefail

# Keep the Daily Main Snapshot inventory aligned with the actual
# ai-workspace-services repository names. A stale renamed repository makes
# actions/create-github-app-token fail before immutable tag resolution.

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
workflow="${repo_root}/.github/workflows/daily-main-snapshot.yaml"
inventory="${repo_root}/.github/daily-snapshot-builds.json"

python3 - "${workflow}" "${inventory}" <<'PY'
import json
import re
import sys
from pathlib import Path

workflow_path = Path(sys.argv[1])
inventory_path = Path(sys.argv[2])

expected = [
    "accounts",
    "billing-service",
    "content-service",
    "portal",
    "edge-gateway",
    "frontend-router",
    "postgresql",
]
expected_full = {f"ai-workspace-services/{name}" for name in expected}

workflow = workflow_path.read_text(encoding="utf-8")
inventory = json.loads(inventory_path.read_text(encoding="utf-8"))

if "postgresql.svc.plus" in workflow or "postgresql.svc.plus" in inventory_path.read_text(encoding="utf-8"):
    raise SystemExit("stale ai-workspace-services/postgresql.svc.plus reference remains")

configured = {
    item["repository"]
    for item in inventory["repositories"]
    if item["repository"].startswith("ai-workspace-services/")
}
if configured != expected_full:
    raise SystemExit(f"snapshot inventory mismatch: {sorted(configured)}")

service_token_block = re.search(
    r"id: app-token-services(?P<body>.*?)(?=\n\s*- name: Create GitHub App installation token for xstream)",
    workflow,
    re.DOTALL,
)
if not service_token_block:
    raise SystemExit("Services installation-token step is missing")
for name in expected:
    if not re.search(rf"^\s+{re.escape(name)}\s*$", service_token_block.group("body"), re.MULTILINE):
        raise SystemExit(f"Services token block omits {name}")

expected_expression = "accounts,billing-service,content-service,portal,edge-gateway,frontend-router,postgresql"
if expected_expression not in workflow:
    raise SystemExit("snapshot matrix token repository expression is incomplete")

print("daily_snapshot_services_repository_contract_test: PASS")
PY
