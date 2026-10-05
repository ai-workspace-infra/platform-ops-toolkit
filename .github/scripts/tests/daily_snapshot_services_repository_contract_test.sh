#!/usr/bin/env bash
set -euo pipefail

# Keep the Daily Main Snapshot inventory aligned with the actual
# ai-workspace-services repository names. A stale renamed repository makes
# actions/create-github-app-token fail before immutable tag resolution.

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
workflow="${repo_root}/.github/workflows/daily-main-snapshot.yaml"
inventory="${repo_root}/.github/daily-snapshot-builds.json"
tag_helper="${repo_root}/docs/tasks/tag-ai-workspace-mains.sh"
wait_helper="${repo_root}/.github/scripts/snapshots/wait-daily-snapshot-builds.sh"

python3 - "${workflow}" "${inventory}" "${tag_helper}" "${wait_helper}" <<'PY'
import json
import re
import sys
from pathlib import Path

workflow_path = Path(sys.argv[1])
inventory_path = Path(sys.argv[2])
tag_helper_path = Path(sys.argv[3])
wait_helper_path = Path(sys.argv[4])

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
tag_helper_text = tag_helper_path.read_text(encoding="utf-8")
wait_helper_text = wait_helper_path.read_text(encoding="utf-8")

if "postgresql.svc.plus" in workflow or "postgresql.svc.plus" in inventory_path.read_text(encoding="utf-8"):
    raise SystemExit("stale ai-workspace-services/postgresql.svc.plus reference remains")
if "ai-workspace-services/postgresql)" not in tag_helper_text or "ai-workspace-services/postgresql)" not in wait_helper_text:
    raise SystemExit("snapshot tag/wait helpers must route the renamed postgresql repository")

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
