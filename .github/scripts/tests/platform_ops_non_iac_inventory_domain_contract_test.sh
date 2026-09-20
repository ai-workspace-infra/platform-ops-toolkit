#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
script="${repo_root}/.github/scripts/platform-ops/deploy/platform-ops_deploy_render-non-iac-agent-proxy-inventory.py"

python3 - "${script}" <<'PY'
import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

script = Path(sys.argv[1])

def run(environment: str, fqdn: str, expected_ok: bool) -> None:
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        topology = root / "topology.yaml"
        vault = root / "vault.json"
        inventory = root / "inventory.yaml"
        output = root / "output"
        topology.write_text(
            "metadata:\n  environment: {environment}\nspec:\n  pools:\n".format(
                environment=environment
            )
            + "\n".join(
                "    - name: {pool}\n      entrypoint:\n        fqdn: {pool}-xconnect.{suffix}\n"
                "      nodes:\n        - id: {pool}-01\n          connection_source: {source}\n".format(
                    pool=pool,
                    suffix="onwalk.net" if environment == "uat" else "svc.plus",
                    source="vault" if pool == "tw" else "terraform_cmdb",
                )
                for pool in ("jp", "us", "sg", "tw")
            ),
            encoding="utf-8",
        )
        # Replace the selected TW fqdn for the negative PROD-domain leak case.
        topology.write_text(
            topology.read_text(encoding="utf-8").replace("tw-xconnect.onwalk.net", fqdn),
            encoding="utf-8",
        )
        vault.write_text(
            json.dumps({"data": {"data": {fqdn: {
                "public_ipv4": "192.0.2.10",
                "ansible_user": "root",
                "SSH_PASSWORD": "test-only",
            }}}}),
            encoding="utf-8",
        )
        env = os.environ.copy()
        env.update({
            "DEPLOYMENT_ENV": environment,
            "XCONNECT_GITOPS_CONFIG": str(topology),
            "XCONNECT_VAULT_RESPONSE_FILE": str(vault),
            "XCONNECT_INVENTORY_FILE": str(inventory),
            "XCONNECT_NODE_ID": "tw-01",
            "GITHUB_OUTPUT": str(output),
        })
        result = subprocess.run([sys.executable, str(script)], env=env, text=True, capture_output=True)
        if expected_ok:
            assert result.returncode == 0, result.stderr
            assert "domain=tw-xconnect.onwalk.net" in output.read_text(encoding="utf-8")
        else:
            assert result.returncode != 0, result.stdout + result.stderr
            assert "must use 'tw-xconnect.onwalk.net'" in result.stderr

run("uat", "tw-xconnect.onwalk.net", True)
run("uat", "tw-xconnect.svc.plus", False)
print("platform_ops_non_iac_inventory_domain_contract_test: PASS")
PY
