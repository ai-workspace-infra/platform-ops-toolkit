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
if dns_mode is None or dns_mode.get("default") != "none" or dns_mode.get("options") != ["none", "uat-records", "prod-cutover"]:
    raise SystemExit("serverless workflow must default DNS mode to none and expose the standard DNS choices")

# The deployment lanes used to fan out from preflight in parallel and converge
# only at serverless_domains. That convergence protects the public DNS/CORS
# chain, but not live traffic: the SSR boundaries, the router and the edge
# gateway update existing routes in place, so a new Worker reaches real users
# the moment it is published, without waiting for serverless_domains. A backend
# that had just failed therefore got a freshly shipped frontend pointing at it.
# PROD safety now outranks the few minutes of parallelism those lanes bought, so
# the Cloudflare lanes wait on backend_gate. Supabase and Cloud Run still fan out
# from preflight directly — nothing downstream of them is user-visible yet.
preflight_only = {
    "supabase",
    "cloud_run",
}
for job in preflight_only:
    needs = jobs[job].get("needs")
    if needs != "preflight":
        raise SystemExit(f"{job} must depend only on preflight, got {needs!r}")

gated_frontend = {
    "cloudflare_ssr",
    "frontend_router",
    "edge_gateway",
}
for job in gated_frontend:
    needs = jobs[job].get("needs")
    if needs != ["preflight", "backend_gate"]:
        raise SystemExit(
            f"{job} must wait on backend_gate so a failed or partial Cloud Run "
            f"rollout cannot ship a frontend against it, got {needs!r}"
        )

# The gate is only meaningful if it actually consumes the matrix result: with
# fail-fast: false a single failed service still reports the matrix as failed,
# and that is the signal which must block the frontend.
backend_gate = jobs["backend_gate"]
if backend_gate.get("needs") != ["preflight", "cloud_run"]:
    raise SystemExit(
        f"backend_gate must aggregate the cloud_run matrix, got {backend_gate.get('needs')!r}"
    )
if "needs.cloud_run.result" not in yaml.safe_dump(backend_gate.get("steps", [])):
    raise SystemExit("backend_gate must consume needs.cloud_run.result")

# Cloud Run services share the Supabase Session Pooler quota. The accounts
# runtime has separate business and admin-settings pools, so replacing
# accounts and billing concurrently can exhaust pool_size before either new
# revision becomes ready. Keep the matrix jobs independent for failure
# reporting, but serialize the actual deployments.
cloud_run_strategy = jobs["cloud_run"].get("strategy", {})
if cloud_run_strategy.get("max-parallel") != 1:
    raise SystemExit("cloud_run matrix must serialize deployments with max-parallel: 1")

# static_pages is the one deliberate exception: the Pages deployment publishes
# the client chunks of every SSR boundary (assetPrefix -> static_cdn_url), so it
# has to wait for the boundary builds instead of racing them.
static_pages_needs = jobs["static_pages"].get("needs")
if static_pages_needs != ["preflight", "cloudflare_ssr"]:
    raise SystemExit(
        f"static_pages must depend on preflight and cloudflare_ssr, got {static_pages_needs!r}"
    )

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
