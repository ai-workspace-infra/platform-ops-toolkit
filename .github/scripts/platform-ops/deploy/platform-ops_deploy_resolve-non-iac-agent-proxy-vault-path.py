#!/usr/bin/env python3
"""Resolve the Vault KV v2 path for a non-IaC XConnect node."""

from __future__ import annotations

import os
import sys
from pathlib import Path

import yaml


def main() -> int:
    topology = yaml.safe_load(Path(os.environ["XCONNECT_GITOPS_CONFIG"]).read_text(encoding="utf-8")) or {}
    node_id = os.environ["XCONNECT_NODE_ID"]
    spec = topology.get("spec") or {}
    node = None
    for pool in spec.get("pools") or []:
        for candidate in pool.get("nodes") or []:
            if candidate.get("id") == node_id:
                node = candidate
                break
        if node is not None:
            break
    if node is None:
        raise SystemExit(f"node {node_id!r} is not declared in the XConnect topology")

    path = node.get("credentials_vault_path")
    if not path:
        path = (spec.get("connection") or {}).get("vault_secret")
    if not path:
        raise SystemExit(f"no Vault path is declared for non-IaC node {node_id}")

    path = str(path).strip()
    if path.startswith("kv/data/"):
        api_path = path
    elif path.startswith("kv/"):
        api_path = f"kv/data/{path[3:]}"
    else:
        api_path = f"kv/data/{path.lstrip('/')}"

    output_file = os.environ.get("GITHUB_OUTPUT")
    if not output_file:
        raise SystemExit("GITHUB_OUTPUT is required")
    with open(output_file, "a", encoding="utf-8") as stream:
        stream.write(f"vault_api_path={api_path}\n")
    print(f"Resolved Vault path for {node_id}: {api_path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
