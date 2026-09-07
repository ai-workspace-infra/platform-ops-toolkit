#!/usr/bin/env bash
set -euo pipefail

# Contract test: the Cloud Run accounts deployment must carry this
# environment's browser origins. accounts rejects any Origin outside its CORS
# allowlist with an empty 403, which the portal can only surface as a generic
# error, and a curl probe without an Origin header still returns a normal 401 --
# so nothing downstream notices when this wiring is missing.

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
orchestrator="${repo_root}/scripts/serverless_uat/deploy_orchestrator.py"
deploy_script="${repo_root}/scripts/serverless_uat/deploy_cloudrun_services.sh"
workflow="${repo_root}/.github/workflows/serverless-orchestrator.yml"

python3 - "${orchestrator}" <<'EOF'
import importlib.util
import json
import os
import sys
import tempfile

spec = importlib.util.spec_from_file_location("deploy_orchestrator", sys.argv[1])
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

resolve = mod.resolve_console_origins

document = {
    "kind": "EdgeRoutingConfig",
    "spec": {
        "serverless": {
            "console_host": "console-cloudflare-uat.onwalk.net",
            "console_aliases": ["console-legacy-uat.onwalk.net"],
            "accounts_host": "accounts-cloudflare-uat.onwalk.net",
        },
        "runtime": {
            "routing": {
                "dns": {
                    "canonical_records": {
                        "console-uat.onwalk.net": "console-cloudflare-uat.onwalk.net",
                        "accounts-uat.onwalk.net": "accounts-cloudflare-uat.onwalk.net",
                    }
                }
            }
        },
        "domains": {
            "console-uat.onwalk.net": {
                "selfhost": "console-vps-uat.onwalk.net",
                "serverless": "console-cloudflare-uat.onwalk.net",
            },
            "accounts-uat.onwalk.net": {
                "selfhost": "accounts-vps-uat.onwalk.net",
                "serverless": "accounts-cloudflare-uat.onwalk.net",
            },
        },
    },
}

with tempfile.TemporaryDirectory() as tmp:
    path = os.path.join(tmp, "edge-routing.json")
    with open(path, "w", encoding="utf-8") as handle:
        json.dump(document, handle)

    origins = resolve(path)

    # The console host itself must always be present: it is the Origin the
    # portal sends on every login request.
    assert origins[0] == "https://console-cloudflare-uat.onwalk.net", origins

    # The canonical alias resolves to the same console host, so a user arriving
    # through it sends the alias as the Origin instead.
    assert "https://console-uat.onwalk.net" in origins, origins

    # A hostname that still answers for the console but is outside the canonical
    # alias contract has to be declared explicitly, otherwise every browser
    # login from it is rejected with an empty 403.
    assert "https://console-legacy-uat.onwalk.net" in origins, origins

    # Hosts belonging to other services must not leak into the allowlist.
    assert not any("accounts-" in origin for origin in origins), origins

    # Aliases appear in both canonical_records and domains; they must be
    # de-duplicated rather than repeated.
    assert len(origins) == len(set(origins)), origins
    assert len(origins) == 3, origins

    # A missing console host yields no origins rather than a bogus "https://".
    empty_path = os.path.join(tmp, "empty.json")
    with open(empty_path, "w", encoding="utf-8") as handle:
        json.dump({"kind": "EdgeRoutingConfig", "spec": {}}, handle)
    assert resolve(empty_path) == [], resolve(empty_path)

    oauth_path = os.path.join(tmp, "github.json")
    with open(oauth_path, "w", encoding="utf-8") as handle:
        json.dump(
            {
                "enabled": True,
                "client_id": "test-client-id",
                "redirect_url": "https://accounts-cloudflare-uat.onwalk.net/api/auth/oauth/callback/github",
                "frontend_url": "https://console-cloudflare-uat.onwalk.net",
                "vault_secret_path": "kv/data/uat/accounts/oauth/github",
                "vault_secret_key": "client_secret",
            },
            handle,
        )

    original_config = mod.GITOPS_OAUTH_GITHUB_CONFIG
    original_fetch = mod.fetch_vault_path
    mod.GITOPS_OAUTH_GITHUB_CONFIG = oauth_path
    mod.VAULT_ENV_PATH = "uat"
    mod.fetch_vault_path = lambda path: {
        "client_secret": "test-client-secret"
    } if path == "kv/data/uat/accounts/oauth/github" else {}
    try:
        oauth = mod.resolve_github_oauth_runtime()
    finally:
        mod.GITOPS_OAUTH_GITHUB_CONFIG = original_config
        mod.fetch_vault_path = original_fetch
    assert oauth == {
        "GITHUB_CLIENT_ID": "test-client-id",
        "GITHUB_CLIENT_SECRET": "test-client-secret",
        "OAUTH_FRONTEND_URL": "https://console-cloudflare-uat.onwalk.net",
        "OAUTH_GITHUB_REDIRECT_URL": "https://accounts-cloudflare-uat.onwalk.net/api/auth/oauth/callback/github",
    }, oauth

# An unset config path is not an error here; the orchestrator warns instead.
assert resolve("") == []

print("resolve_console_origins tests: PASS")
EOF

# The deploy script must forward the resolved value to the accounts service.
grep -q 'ALLOWED_ORIGINS=\${ALLOWED_ORIGINS}' "${deploy_script}" || {
  echo "deploy_cloudrun_services.sh must pass ALLOWED_ORIGINS to accounts" >&2
  exit 1
}

for required in GITHUB_CLIENT_ID GITHUB_CLIENT_SECRET OAUTH_FRONTEND_URL OAUTH_GITHUB_REDIRECT_URL; do
  grep -q "${required}=\${${required}" "${deploy_script}" || {
    echo "deploy_cloudrun_services.sh must pass ${required} to accounts" >&2
    exit 1
  }
done

# The Cloud Run job must render the GitOps topology and hand it to the deploy
# step, otherwise resolve_console_origins has nothing to read.
python3 - "${workflow}" <<'EOF'
import sys

try:
    import yaml
except ImportError:  # pragma: no cover - yaml ships with the CI runner
    print("PyYAML unavailable; skipping workflow wiring assertions")
    sys.exit(0)

with open(sys.argv[1], encoding="utf-8") as handle:
    workflow = yaml.safe_load(handle)

steps = workflow["jobs"]["cloud_run"]["steps"]
names = [step.get("name", "") for step in steps]
assert "Render GitOps runtime topology YAML" in names, names

deploy_step = next(step for step in steps if step.get("name") == "Deploy Cloud Run service")
assert "CLOUDFLARE_BOUNDARY_CONFIG" in deploy_step.get("env", {}), deploy_step.get("env")
assert "GITOPS_OAUTH_GITHUB_CONFIG" in deploy_step.get("env", {}), deploy_step.get("env")

gitops_step = next(step for step in steps if step.get("name") == "Checkout GitOps runtime topology")
sparse_checkout = gitops_step.get("with", {}).get("sparse-checkout", "")
assert "services/accounts/${{ inputs.vault_env_path || 'uat' }}/oauth/github.json" in sparse_checkout, sparse_checkout

print("cloud_run workflow wiring: PASS")
EOF

echo "cloudrun_accounts_allowed_origins_test: PASS"
