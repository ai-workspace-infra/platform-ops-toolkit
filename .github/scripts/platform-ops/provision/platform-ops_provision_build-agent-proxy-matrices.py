#!/usr/bin/env python3
"""Build the IaC and non-IaC Agent Proxy deployment matrices.

The Terraform CMDB is authoritative for AWS nodes.  GitOps is authoritative
for manually provisioned regional nodes; the current production topology has
one such node, PH.  The compatibility fallback for a topology created before
the explicit connection_source field treats only the PH pool as non-IaC.
"""

from __future__ import annotations

import json
import os
import sys
from pathlib import Path

import yaml


EXPECTED_POOLS = {"jp", "us", "hk", "ph"}


def output(name: str, value: object) -> None:
    output_file = os.environ.get("GITHUB_OUTPUT")
    if not output_file:
        raise SystemExit("GITHUB_OUTPUT is required")
    rendered = json.dumps(value, separators=(",", ":")) if isinstance(value, (list, dict)) else str(value)
    with open(output_file, "a", encoding="utf-8") as stream:
        stream.write(f"{name}={rendered}\n")


def main() -> int:
    cmdb_file = Path(os.environ["CMDB_FILE"])
    gitops_file = Path(os.environ.get("GITOPS_XCONNECT_CONFIG", ""))

    cmdb = json.loads(cmdb_file.read_text(encoding="utf-8"))
    iac_hosts = [
        host
        for host, facts in cmdb.items()
        if "agent_proxy" in (facts.get("groups") or [])
    ]
    if len(iac_hosts) != 3:
        raise SystemExit(
            "PROD Agent Proxy IaC matrix must contain exactly JP, US, and HK; "
            f"found {len(iac_hosts)} CMDB hosts"
        )
    output("hosts_agent_proxy_iac", iac_hosts)

    non_iac_hosts: list[str] = []
    region_count = 0
    if not gitops_file.is_file():
        raise SystemExit(f"PROD XConnect topology is missing: {gitops_file}")
    if gitops_file.is_file():
        topology = yaml.safe_load(gitops_file.read_text(encoding="utf-8")) or {}
        pools = (topology.get("spec") or {}).get("pools") or []
        pool_names = {pool.get("name") for pool in pools}
        if pool_names != EXPECTED_POOLS:
            raise SystemExit(
                "PROD XConnect topology must declare exactly jp, us, hk, and ph pools; "
                f"found {sorted(pool_names)}"
            )
        region_count = len(pools)
        for pool in pools:
            for node in pool.get("nodes") or []:
                source = node.get("connection_source")
                legacy_ph = source is None and pool.get("name") == "ph"
                if source == "vault" or legacy_ph:
                    node_id = node.get("id")
                    if not node_id:
                        raise SystemExit(f"non-IaC pool {pool.get('name')} has a node without id")
                    non_iac_hosts.append(node_id)

    if len(non_iac_hosts) != 1:
        raise SystemExit(
            "PROD Agent Proxy non-IaC matrix must contain exactly the PH node; "
            f"found {non_iac_hosts!r}"
        )

    output("hosts_agent_proxy_non_iac", non_iac_hosts)
    output("agent_proxy_region_count", region_count)
    print(
        "Agent Proxy deployment matrices: "
        f"IaC={iac_hosts!r}, non-IaC={non_iac_hosts!r}, regions={region_count}"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
