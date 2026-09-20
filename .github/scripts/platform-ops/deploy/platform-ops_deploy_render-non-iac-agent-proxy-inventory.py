#!/usr/bin/env python3
"""Render a temporary Ansible inventory for one Vault-backed XConnect node."""

from __future__ import annotations

import json
import os
import sys
from pathlib import Path

import yaml


def fail(message: str) -> None:
    raise SystemExit(message)


def main() -> int:
    topology_file = Path(os.environ["XCONNECT_GITOPS_CONFIG"])
    vault_file = Path(os.environ["XCONNECT_VAULT_RESPONSE_FILE"])
    inventory_file = Path(os.environ["XCONNECT_INVENTORY_FILE"])
    node_id = os.environ["XCONNECT_NODE_ID"]
    deployment_env = os.environ.get("DEPLOYMENT_ENV", "").strip()
    deploy_key_file = os.environ.get("XCONNECT_DEPLOY_KEY_FILE", "").strip()

    topology = yaml.safe_load(topology_file.read_text(encoding="utf-8")) or {}
    topology_env = ((topology.get("metadata") or {}).get("environment") or "").strip()
    if deployment_env not in {"uat", "prod"}:
        fail(f"DEPLOYMENT_ENV must be uat or prod, got {deployment_env!r}")
    if topology_env != deployment_env:
        fail(
            f"GitOps topology environment {topology_env!r} does not match "
            f"deployment environment {deployment_env!r}"
        )
    pools = (topology.get("spec") or {}).get("pools") or []
    expected_pools = {
        "uat": {"jp", "us", "sg", "tw"},
        "prod": {"jp", "us", "sg", "ph", "tw"},
    }[deployment_env]
    if {pool.get("name") for pool in pools} != expected_pools:
        fail(
            f"{deployment_env.upper()} XConnect topology must declare exactly "
            f"these pools: {sorted(expected_pools)}"
        )

    selected = None
    selected_pool = None
    for pool in pools:
        for node in pool.get("nodes") or []:
            if node.get("id") == node_id:
                selected = node
                selected_pool = pool
                break
        if selected is not None:
            break
    if selected is None or selected_pool is None:
        fail(f"non-IaC node {node_id!r} is not declared in the XConnect topology")

    source = selected.get("connection_source")
    if source not in (None, "vault"):
        fail(f"node {node_id!r} is not a Vault-backed non-IaC node")
    if source is None and selected_pool.get("name") != "ph":
        fail(f"legacy topology without connection_source is only accepted for the PH pool: {node_id}")

    domain = ((selected_pool.get("entrypoint") or {}).get("fqdn") or "").strip()
    expected_suffix = {"uat": ".onwalk.net", "prod": ".svc.plus"}[deployment_env]
    expected_domain = f"{selected_pool.get('name')}-xconnect{expected_suffix}"
    if domain != expected_domain:
        fail(
            f"{deployment_env.upper()} pool {selected_pool.get('name')!r} must use "
            f"{expected_domain!r}, found {domain!r}"
        )
    vault = json.loads(vault_file.read_text(encoding="utf-8"))
    secret = ((vault.get("data") or {}).get("data") or {})
    # The regional FQDN is the stable Vault record key.  A node ID is an
    # operational label and can change when the provider host is replaced.
    node_secret = secret.get(domain)
    if not isinstance(node_secret, dict):
        node_secret = (secret.get("nodes") or {}).get(domain)
    # Keep old node-keyed records usable during the transition.
    if not isinstance(node_secret, dict):
        node_secret = secret.get(node_id)
    if not isinstance(node_secret, dict):
        node_secret = (secret.get("nodes") or {}).get(node_id)
    if not isinstance(node_secret, dict):
        # Older records store the single PH node directly at the KV root.
        node_secret = secret

    # The Vault record is the source of truth for manually provisioned nodes.
    # GitOps may retain stale labels after a provider-side replacement, so do
    # not let optional topology values override the live connection details.
    host = node_secret.get("public_ipv4") or node_secret.get("ip") or selected.get("ansible_host")
    user = node_secret.get("ansible_user") or selected.get("ansible_user")
    password = node_secret.get("SSH_PASSWORD") or node_secret.get("ansible_password")
    if not host or not user or not password or not domain:
        fail(f"Vault/GitOps metadata is incomplete for non-IaC node {node_id}")

    host_vars = {
        "ansible_host": host,
        "ansible_user": user,
        "ansible_password": password,
        "service_domains": [domain],
        "xconnect_region": selected_pool.get("region", "ph-mnl"),
        "xconnect_pool": selected_pool.get("name", "ph"),
        "xconnect_fqdn": domain,
        "xconnect_connection_source": "vault",
    }
    if deploy_key_file:
        host_vars["ansible_ssh_private_key_file"] = deploy_key_file

    inventory = {
        "all": {
            "children": {
                "agent_proxy": {
                    "hosts": {
                        node_id: host_vars
                    }
                },
                "xray_exporter": {"children": {"agent_proxy": {}}},
            }
        }
    }
    inventory_file.write_text(yaml.safe_dump(inventory, sort_keys=False), encoding="utf-8")
    os.chmod(inventory_file, 0o600)

    output_file = os.environ.get("GITHUB_OUTPUT")
    if output_file:
        with open(output_file, "a", encoding="utf-8") as stream:
            stream.write(f"domain={domain}\n")
            stream.write(f"region={selected_pool.get('region', 'ph-mnl')}\n")
            stream.write(f"pool={selected_pool.get('name', 'ph')}\n")
    print(f"Rendered non-IaC Agent Proxy inventory for {node_id} ({selected_pool.get('region', 'ph-mnl')})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
