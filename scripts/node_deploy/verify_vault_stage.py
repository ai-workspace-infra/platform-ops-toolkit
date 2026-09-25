#!/usr/bin/env python3
"""Require the manual Vault init/unseal checkpoints before later node stages."""

from __future__ import annotations

import argparse
import json
import subprocess
from pathlib import Path

from render_inventory import validate


def probe(node: dict, key: Path, known_hosts: Path) -> dict:
    command = [
        "ssh", "-i", str(key),
        "-o", "BatchMode=yes",
        "-o", "ConnectTimeout=12",
        "-o", "StrictHostKeyChecking=yes",
        "-o", f"UserKnownHostsFile={known_hosts}",
        "-o", "HostKeyAlgorithms=ssh-ed25519",
        "-p", str(node.get("ssh_port", 22)),
        f"{node['ssh_user']}@{node['address']}",
        "curl -sS --max-time 8 http://127.0.0.1:8200/v1/sys/health",
    ]
    result = subprocess.run(command, capture_output=True, text=True, timeout=25, check=False)
    if result.returncode != 0:
        raise ValueError(f"{node['id']}: Vault local health endpoint is unreachable")
    try:
        health = json.loads(result.stdout)
    except json.JSONDecodeError as error:
        raise ValueError(f"{node['id']}: Vault health response is not JSON") from error
    if not isinstance(health, dict):
        raise ValueError(f"{node['id']}: Vault health response is invalid")
    return health


def verify(contract: dict, stage: str, health_by_node: dict[str, dict]) -> None:
    nodes = contract["spec"]["nodes"]
    if stage == "vault-shared-peers":
        leaders = [node for node in nodes if "vault_shared_leader" in node["groups"]]
        if len(leaders) != 1:
            raise ValueError("exactly one declared Vault leader is required")
        leader = health_by_node[leaders[0]["id"]]
        if leader.get("initialized") is not True or leader.get("sealed") is not False:
            raise ValueError("Vault leader must be manually initialized and unsealed before peers")
        return
    if stage not in {"node-process-metrics", "xconnect-gateway", "xconnect-one"}:
        return
    cluster_ids: set[str] = set()
    active = 0
    standby = 0
    for node in nodes:
        health = health_by_node[node["id"]]
        if health.get("initialized") is not True or health.get("sealed") is not False:
            raise ValueError(f"{node['id']}: Vault must be manually unsealed before {stage}")
        cluster_id = health.get("cluster_id")
        if not isinstance(cluster_id, str) or not cluster_id:
            raise ValueError(f"{node['id']}: Vault cluster identity is missing")
        cluster_ids.add(cluster_id)
        if health.get("standby") is True:
            standby += 1
        else:
            active += 1
    if len(nodes) != 3 or len(cluster_ids) != 1 or active != 1 or standby != 2:
        raise ValueError("Vault HA requires three unsealed nodes in one cluster: one active and two standby")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--contract", type=Path, required=True)
    parser.add_argument("--stage", required=True)
    parser.add_argument("--key", type=Path, required=True)
    parser.add_argument("--known-hosts", type=Path, required=True)
    args = parser.parse_args()
    contract = validate(json.loads(args.contract.read_text(encoding="utf-8")))
    if args.stage not in contract["spec"]["stages"]:
        raise SystemExit("stage is not declared in the reviewed node contract")
    if args.stage == "vault-shared-peers":
        selected = [node for node in contract["spec"]["nodes"] if "vault_shared_leader" in node["groups"]]
    elif args.stage in {"node-process-metrics", "xconnect-gateway", "xconnect-one"}:
        selected = contract["spec"]["nodes"]
    else:
        return
    health_by_node = {node["id"]: probe(node, args.key, args.known_hosts) for node in selected}
    try:
        verify(contract, args.stage, health_by_node)
    except ValueError as error:
        raise SystemExit(str(error)) from error
    print(f"Vault manual checkpoint verified for {args.stage}")


if __name__ == "__main__":
    main()
