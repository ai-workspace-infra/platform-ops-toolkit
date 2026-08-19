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

    # Hosts belonging to other services must not leak into the allowlist.
    assert not any("accounts-" in origin for origin in origins), origins

    # Aliases appear in both canonical_records and domains; they must be
    # de-duplicated rather than repeated.
    assert len(origins) == len(set(origins)), origins
    assert len(origins) == 2, origins

    # A missing console host yields no origins rather than a bogus "https://".
    empty_path = os.path.join(tmp, "empty.json")
    with open(empty_path, "w", encoding="utf-8") as handle:
        json.dump({"kind": "EdgeRoutingConfig", "spec": {}}, handle)
    assert resolve(empty_path) == [], resolve(empty_path)

# An unset config path is not an error here; the orchestrator warns instead.
assert resolve("") == []

print("resolve_console_origins tests: PASS")
EOF

# The deploy script must forward the resolved value to the accounts service.
grep -q 'ALLOWED_ORIGINS=\${ALLOWED_ORIGINS}' "${deploy_script}" || {
  echo "deploy_cloudrun_services.sh must pass ALLOWED_ORIGINS to accounts" >&2
  exit 1
}

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

print("cloud_run workflow wiring: PASS")
EOF

echo "cloudrun_accounts_allowed_origins_test: PASS"
