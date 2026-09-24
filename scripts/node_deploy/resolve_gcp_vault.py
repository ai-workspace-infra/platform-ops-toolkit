#!/usr/bin/env python3
"""Resolve a reviewed GCP Vault GitOps manifest into the common node contract."""

from __future__ import annotations

import argparse
import ipaddress
import json
from pathlib import Path

import yaml

from render_inventory import validate


STAGES = [
    "vault-shared-leader",
    "vault-shared-peers",
    "node-process-metrics",
    "xconnect-gateway",
    "xconnect-one",
]
STAGE_TARGETS = {
    "vault-shared-leader": ["vault_shared_leader"],
    "vault-shared-peers": ["vault_shared_peers"],
    "node-process-metrics": ["vault_shared_nodes"],
    "xconnect-gateway": ["xconnect_gateway"],
    "xconnect-one": ["xconnect_one"],
}


def resolve(
    manifest: dict,
    instances: list[dict],
    project_id: str,
    ssh_user: str,
    topology: dict | None = None,
) -> dict:
    if manifest.get("kind") != "GCPWorkloadNamespace":
        raise ValueError("expected GCPWorkloadNamespace manifest")
    metadata = manifest["metadata"]
    spec = manifest["spec"]
    if (metadata.get("environment"), spec.get("project_id")) != ("shared", project_id):
        raise ValueError("shared GCP project identity does not match GitOps")
    if spec.get("enable_oslogin") is not True or spec.get("enable_iap_ssh") is not False:
        raise ValueError("shared Vault deployment requires OS Login and direct allowlisted SSH")
    access_mode = spec.get("ssh_access_mode", "bootstrap-public")
    if access_mode == "bootstrap-public":
        if not spec.get("ssh_source_ranges"):
            raise ValueError("bootstrap-public requires an explicit public SSH /32 allowlist")
    elif access_mode == "xconnect-zero":
        if spec.get("ssh_source_ranges") or topology is None:
            raise ValueError("xconnect-zero requires no public SSH allowlist and a verified topology")
        if topology.get("kind") != "XConnectOneNodeSet" or topology.get("metadata", {}).get("environment") != "shared":
            raise ValueError("invalid shared XConnect topology")
        overlay_network = ipaddress.ip_network(topology["spec"]["network"]["cidr"], strict=True)
        network_id = topology["spec"]["network"]["id"]
        if network_id != "net_shared_vault":
            raise ValueError("wrong shared XConnect network")
    else:
        raise ValueError("unsupported SSH access mode")
    declared = spec["resources"]["vault_nodes"]
    if len(declared) != 3 or sorted(node.get("xconnect_role") for node in declared) != [
        "gateway", "one", "one"
    ]:
        raise ValueError("expected one gateway and two One nodes")
    live = {(item.get("name"), item.get("zone", "").split("/")[-1]): item for item in instances}
    nodes = []
    for node in declared:
        name = node["name"]
        zone = node["zone"]
        actual = live.get((name, zone))
        if not actual or actual.get("status") != "RUNNING":
            raise ValueError(f"declared VM {name} ({zone}) is not RUNNING")
        interfaces = actual.get("networkInterfaces", [])
        if len(interfaces) != 1:
            raise ValueError(f"declared VM {name} must have exactly one network interface")
        private_ip = interfaces[0].get("networkIP")
        public_ips = [config.get("natIP") for config in interfaces[0].get("accessConfigs", [])]
        public_ips = [value for value in public_ips if value]
        if node.get("public_ip") is not True or len(public_ips) != 1:
            raise ValueError(f"declared VM {name} is missing its required public SSH address")
        role = node["xconnect_role"]
        if not node.get("ssh_host_ed25519"):
            raise ValueError(f"declared VM {name} has no reviewed SSH host key")
        groups = ["vault_shared_nodes"]
        groups.extend(["vault_shared_leader", "xconnect_gateway"] if role == "gateway" else ["vault_shared_peers", "xconnect_one"])
        resolved = {
                "id": name,
                "provider": "gcp",
                "address": public_ips[0],
                "private_address": private_ip,
                "ssh_host_ed25519": node.get("ssh_host_ed25519"),
                "ssh_user": ssh_user,
                "auth": {"adapter": "gcp-oslogin-ephemeral"},
                "groups": groups,
            }
        if access_mode == "xconnect-zero":
            members = [topology["spec"]["gateway"], *topology["spec"]["fixed_nodes"]]
            target = next((member for member in members if member.get("id") == name), None)
            if target is None:
                raise ValueError(f"XConnect topology is missing {name}")
            overlay = target.get("xconnect", {})
            overlay_ip = overlay.get("overlay_ip")
            internal_dns = overlay.get("internal_dns")
            try:
                assigned = ipaddress.ip_address(overlay_ip)
            except (TypeError, ValueError):
                raise ValueError(f"XConnect node {name} has no assigned overlay IP") from None
            if assigned not in overlay_network or assigned == overlay_network.network_address:
                raise ValueError(f"XConnect node {name} is outside the declared overlay")
            if not isinstance(internal_dns, str) or "." not in internal_dns:
                raise ValueError(f"XConnect node {name} has no internal DNS name")
            resolved["address"] = internal_dns
            resolved["overlay_address"] = overlay_ip
        nodes.append(resolved)
    contract = {
        "apiVersion": "ops.svc.plus/v1alpha1",
        "kind": "NodeDeployment",
        "metadata": {"name": metadata["name"]},
        "spec": {
            "environment": "shared",
            "stages": STAGES,
            "stage_targets": STAGE_TARGETS,
            "nodes": nodes,
        },
    }
    return validate(contract)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--instances", type=Path, required=True)
    parser.add_argument("--project-id", required=True)
    parser.add_argument("--ssh-user", required=True)
    parser.add_argument("--xconnect-topology", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    manifest = yaml.safe_load(args.manifest.read_text(encoding="utf-8"))
    instances = json.loads(args.instances.read_text(encoding="utf-8"))
    topology = yaml.safe_load(args.xconnect_topology.read_text(encoding="utf-8")) if args.xconnect_topology else None
    contract = resolve(manifest, instances, args.project_id, args.ssh_user, topology)
    args.output.write_text(json.dumps(contract, indent=2) + "\n", encoding="utf-8")
    args.output.chmod(0o600)
    print(f"resolved {len(contract['spec']['nodes'])} GCP Vault nodes into {args.output}")


if __name__ == "__main__":
    main()
