#!/usr/bin/env python3
"""Validate the non-sensitive PersonalAIAggregator GitOps contract."""

from __future__ import annotations

import hashlib
import ipaddress
import sys
from pathlib import Path

import yaml


def fail(message: str) -> None:
    raise SystemExit(f"manifest validation failed: {message}")


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit("usage: validate_ai_aggregator_manifest.py <manifest>")
    path = Path(sys.argv[1])
    data = yaml.safe_load(path.read_text())
    if data.get("kind") != "PersonalAIAggregator":
        fail("kind must be PersonalAIAggregator")
    spec = data.get("spec", {})
    if spec.get("entrypoint", {}).get("component") != "caddy":
        fail("Caddy must be the public entrypoint")
    if spec.get("new_api", {}).get("bind_address") not in {"127.0.0.1", "::1"}:
        fail("New API must bind to loopback")

    # Testing environment constraints: AWS Spot t4g 1h rule
    test_env = spec.get("testing_environment")
    if test_env:
        if test_env.get("provider") != "aws":
            fail("testing environment provider must be aws")
        if test_env.get("architecture") != "arm64":
            fail("testing environment architecture must be arm64")
        if not test_env.get("spot_instance"):
            fail("testing environment must use spot instances (spot_instance: true)")
        if test_env.get("max_runtime_minutes") != 60:
            fail("testing environment max_runtime_minutes must be 60")

    nodes = {node["id"] for node in spec.get("nodes", [])}
    if spec.get("new_api", {}).get("node") not in nodes:
        fail("New API node is not declared")

    instances = spec.get("cpa_instances", [])
    ids = [entry.get("id") for entry in instances]
    ports = [entry.get("port") for entry in instances]
    if not instances or len(ids) != len(set(ids)) or len(ports) != len(set(ports)):
        fail("CPA instance IDs and ports must be unique and non-empty")
    for instance in instances:
        if instance.get("node") not in nodes:
            fail(f"CPA instance {instance.get('id')} refers to an unknown node")
        if instance.get("bind_address") not in {"127.0.0.1", "::1"}:
            fail(f"CPA instance {instance.get('id')} must bind to loopback")
        if not str(instance.get("auth_secret_ref", "")).startswith("vault://"):
            fail(f"CPA instance {instance.get('id')} lacks a Vault reference")

    enabled = bool(spec.get("enabled"))
    cidrs = spec.get("entrypoint", {}).get("source_cidrs", [])
    if enabled:
        if not cidrs:
            fail("enabled deployment requires an IP allowlist")
        for cidr in cidrs:
            network = ipaddress.ip_network(cidr, strict=False)
            if network.prefixlen not in {32, 128}:
                fail("v1 only accepts fixed /32 or /128 source addresses")
        for name in ("new_api", "cliproxyapi"):
            artifact = spec.get("artifacts", {}).get(name, {})
            if not artifact.get("revision"):
                fail(f"enabled deployment requires {name} revision")
            if len(str(artifact.get("sha256", ""))) != 64:
                fail(f"enabled deployment requires {name} sha256")
            try:
                int(artifact["sha256"], 16)
            except ValueError:
                fail(f"{name} sha256 is not hexadecimal")
        if not spec.get("new_api", {}).get("start_command"):
            fail("enabled deployment requires a verified New API loopback start command")

    print(f"valid PersonalAIAggregator manifest: {path}")


if __name__ == "__main__":
    main()
