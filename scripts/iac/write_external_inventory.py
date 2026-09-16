#!/usr/bin/env python3
"""Render a read-only existing-resource declaration into a safe inventory record."""

from __future__ import annotations

import argparse
import json
from datetime import UTC, datetime
from pathlib import Path

import yaml


SENSITIVE = ("secret", "token", "password", "private_key", "access_key", "credential")


def without_secrets(value):
    if isinstance(value, dict):
        return {
            key: without_secrets(item)
            for key, item in value.items()
            if not any(marker in key.lower() for marker in SENSITIVE)
        }
    if isinstance(value, list):
        return [without_secrets(item) for item in value]
    return value


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--provider", required=True)
    parser.add_argument("--environment", required=True)
    parser.add_argument("--project", required=True)
    parser.add_argument("--account", required=True)
    parser.add_argument("--workspace", required=True)
    parser.add_argument("--inventory-output", type=Path, required=True)
    parser.add_argument("--run-output", type=Path, required=True)
    args = parser.parse_args()

    document = yaml.safe_load(args.manifest.read_text(encoding="utf-8")) or {}
    metadata = document.get("global", document)
    expected = {
        "management_mode": "existing",
        "provisioner": "ansible",
        "lifecycle": "external",
    }
    for key, value in expected.items():
        if metadata.get(key) != value:
            raise SystemExit(f"{args.manifest}: {key} must be {value!r} for an external provider")

    resources = document.get("hosts") or document.get("resources") or document.get("nodes") or []
    if not isinstance(resources, list) or not resources:
        raise SystemExit(f"{args.manifest}: declare at least one hosts/resources/nodes entry")
    if any(not isinstance(item, dict) or not item.get("name") for item in resources):
        raise SystemExit(f"{args.manifest}: every external resource requires a name")

    identity = {
        "provider": args.provider,
        "environment": args.environment,
        "project": args.project,
        "account": args.account,
        "workspace": args.workspace,
    }
    inventory = {
        "schema_version": 1,
        **identity,
        **expected,
        "source_manifest": str(args.manifest),
        "resources": without_secrets(resources),
    }
    run = {
        "schema_version": 1,
        **identity,
        "operation": "external-inventory-sync",
        "recorded_at": datetime.now(UTC).isoformat(),
        "resource_count": len(resources),
    }
    args.inventory_output.write_text(json.dumps(inventory, indent=2) + "\n", encoding="utf-8")
    args.run_output.write_text(json.dumps(run, indent=2) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
