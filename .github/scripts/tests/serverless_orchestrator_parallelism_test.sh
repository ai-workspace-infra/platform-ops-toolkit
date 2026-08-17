#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
workflow="${repo_root}/.github/workflows/serverless-orchestrator.yml"

python3 - "${workflow}" <<'PY'
from pathlib import Path
import sys

import yaml

workflow = yaml.safe_load(Path(sys.argv[1]).read_text(encoding="utf-8"))
jobs = workflow["jobs"]
parallel = {
    "supabase",
    "cloud_run",
    "cloudflare_ssr",
    "frontend_router",
    "edge_gateway",
    "static_pages",
}
for job in parallel:
    needs = jobs[job].get("needs")
    if needs != "preflight":
        raise SystemExit(f"{job} must depend only on preflight, got {needs!r}")

expected_readiness_needs = {
    "preflight",
    "supabase",
    "cloud_run",
    "cloudflare_ssr",
    "frontend_router",
    "edge_gateway",
    "static_pages",
}
actual_readiness_needs = set(jobs["serverless_domains"].get("needs", []))
if actual_readiness_needs != expected_readiness_needs:
    raise SystemExit(
        "serverless_domains must be the single readiness fan-in; "
        f"got {sorted(actual_readiness_needs)!r}"
    )
PY

echo "serverless_orchestrator_parallelism_test: PASS"
