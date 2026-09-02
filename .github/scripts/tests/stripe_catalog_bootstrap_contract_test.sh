#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
workflow="${repo_root}/.github/workflows/serverless-orchestrator.yml"
selfhost_workflow="${repo_root}/.github/workflows/selfhost-orchestrator.yml"
bootstrap="${repo_root}/scripts/serverless_uat/bootstrap_stripe_catalog.sh"

bash -n "${bootstrap}"

python3 - "${workflow}" "${selfhost_workflow}" "${bootstrap}" <<'PY'
from pathlib import Path
import sys

import yaml

workflow = yaml.safe_load(Path(sys.argv[1]).read_text(encoding="utf-8"))
jobs = workflow["jobs"]
bootstrap = jobs.get("stripe_catalog")
if bootstrap is None:
    raise SystemExit("serverless workflow must bootstrap the Stripe catalog")

if set(bootstrap.get("needs", [])) != {"preflight", "supabase", "cloud_run", "serverless_domains"}:
    raise SystemExit("Stripe bootstrap must wait for schema, Accounts, and public domain readiness")

condition = str(bootstrap.get("if", ""))
for required in (
    'inputs.deploy_cloud_run == true',
    'inputs.deploy_cloudflare == true',
    "needs.serverless_domains.result == 'success'",
):
    if required not in condition:
        raise SystemExit(f"Stripe bootstrap condition must contain {required!r}")

verify_needs = jobs["verify"].get("needs", [])
if "stripe_catalog" not in verify_needs:
    raise SystemExit("deployment summary must wait for Stripe catalog bootstrap")

selfhost = yaml.safe_load(Path(sys.argv[2]).read_text(encoding="utf-8"))["jobs"]
selfhost_bootstrap = selfhost.get("bootstrap_stripe_catalog")
if selfhost_bootstrap is None:
    raise SystemExit("self-hosted workflow must synchronize the Stripe catalog")
if set(selfhost_bootstrap.get("needs", [])) != {
    "provision",
    "initialize_web_saas_databases",
    "switch_dns",
}:
    raise SystemExit("self-hosted Stripe bootstrap must wait for DB initialization and DNS")
if "bootstrap_stripe_catalog" not in selfhost["deployment_summary"].get("needs", []):
    raise SystemExit("self-hosted deployment summary must wait for Stripe bootstrap")

script = Path(sys.argv[3]).read_text(encoding="utf-8")
for required in (
    "kv/${VAULT_ENV_PATH}/billing-service",
    'vault_key_prefix="PROD"',
    'vault_key_prefix="SANDBOX"',
    "STRIPE_WEBHOOK_SECRET",
    "STRIPE_WEBHOOK_URL",
    "scripts/seed-billing-plans.sql",
    "--write-catalog",
    "Accounts bootstrap administrator login failed",
):
    if required not in script:
        raise SystemExit(f"Stripe bootstrap script is missing {required!r}")

workflow_text = Path(sys.argv[1]).read_text(encoding="utf-8")
for required in (
    ".spec.serverless.cloud_run.accounts",
    "ACCOUNTS_BASE_URL=${accounts_run_url}",
):
    if required not in workflow_text:
        raise SystemExit(f"Stripe workflow is missing {required!r}")
PY

echo "stripe_catalog_bootstrap_contract_test: PASS"
