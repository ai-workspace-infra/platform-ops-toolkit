#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
matrix_script="${repo_root}/.github/scripts/platform-ops/provision/platform-ops_provision_build-agent-proxy-matrices.py"

python3 - "${matrix_script}" <<'PY'
import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

script = Path(sys.argv[1])

fixtures = {
    "uat": ({"jp", "us", "sg", "tw"}, {"tw": "tw-existing"}),
    "prod": ({"jp", "us", "sg", "ph", "tw"}, {"ph": "ph-existing", "tw": "tw-existing"}),
}

for environment, (pool_names, external_nodes) in fixtures.items():
    with tempfile.TemporaryDirectory() as temp_dir:
        temp = Path(temp_dir)
        cmdb = temp / "cmdb.json"
        output = temp / "output"
        cmdb.write_text(
            json.dumps({
                f"{region}-xconnect": {"groups": ["agent_proxy"]}
                for region in sorted(pool_names - set(external_nodes))
            }),
            encoding="utf-8",
        )
        topology = temp / "topology.yaml"
        nodes = []
        for region in sorted(pool_names):
            if region in external_nodes:
                nodes.append(f"  - name: {region}\n    nodes:\n      - id: {external_nodes[region]}\n        connection_source: vault")
            else:
                nodes.append(f"  - name: {region}\n    nodes:\n      - id: {region}-xconnect\n        connection_source: terraform_cmdb")
        topology.write_text("spec:\n  pools:\n" + "\n".join(nodes) + "\n", encoding="utf-8")
        env = os.environ.copy()
        env.update({
            "CMDB_FILE": str(cmdb),
            "GITOPS_XCONNECT_CONFIG": str(topology),
            "DEPLOYMENT_ENV": environment,
            "GITHUB_OUTPUT": str(output),
        })
        subprocess.run([sys.executable, str(script)], env=env, check=True, capture_output=True, text=True)
        values = dict(line.rstrip("\n").split("=", 1) for line in output.read_text().splitlines())
        iac_hosts = json.loads(values["hosts_agent_proxy_iac"])
        non_iac_hosts = json.loads(values["hosts_agent_proxy_non_iac"])
        assert len(iac_hosts) == 3, (environment, iac_hosts)
        assert set(non_iac_hosts) == set(external_nodes.values()), (environment, non_iac_hosts)
        assert values["agent_proxy_region_count"] == str(len(pool_names)), (environment, values)

print("platform_ops_agent_proxy_matrix_contract_test: PASS")
PY
