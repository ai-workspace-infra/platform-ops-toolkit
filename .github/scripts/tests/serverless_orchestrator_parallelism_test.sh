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
# PyYAML 5/6 parses the YAML 1.1 boolean-like key `on` as True; newer
# parsers preserve it as a string. Accept both representations in the
# contract test so the assertion is about the workflow, not parser version.
triggers = workflow.get("on", workflow.get(True))
dispatch_inputs = triggers["workflow_dispatch"]["inputs"]
dns_mode = dispatch_inputs.get("dns_mode")
if dns_mode is None or dns_mode.get("default") != "none" or dns_mode.get("options") != ["none", "serverless-cutover"]:
    raise SystemExit("serverless workflow must default DNS mode to none and expose explicit cutover")

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

if jobs["serverless_domains"].get("concurrency", {}).get("group") != "public-dns-${{ inputs.vault_env_path || 'uat' }}":
    raise SystemExit("serverless_domains must serialize public DNS ownership per environment")
PY

echo "serverless_orchestrator_parallelism_test: PASS"
