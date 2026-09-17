#!/usr/bin/env python3
"""Resolve the canonical multi-cloud IaC state contract."""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
REGISTRY_PATH = ROOT / "config" / "iac_provider_registry.json"
SEGMENT = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*$")


def segment(name: str, value: str) -> str:
    if not SEGMENT.fullmatch(value):
        raise ValueError(
            f"{name} must contain only letters, numbers, '.', '_' or '-' and cannot start with punctuation"
        )
    return value


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--environment", required=True)
    parser.add_argument("--project", required=True)
    parser.add_argument("--provider", required=True)
    parser.add_argument("--account", required=True)
    parser.add_argument("--workspace", required=True)
    parser.add_argument("--run-id", default=os.environ.get("GITHUB_RUN_ID", "local"))
    parser.add_argument("--github-output", action="store_true")
    args = parser.parse_args()

    registry = json.loads(REGISTRY_PATH.read_text(encoding="utf-8"))
    if args.provider not in registry:
        raise SystemExit(f"unsupported cloud provider: {args.provider}")

    values = {
        "environment": segment("environment", args.environment),
        "project": segment("project", args.project),
        "provider": segment("provider", args.provider),
        "account": segment("account", args.account),
        "workspace": segment("workspace", args.workspace),
        "run_id": segment("run_id", args.run_id),
    }
    prefix = "/".join(
        (values["environment"], values["project"], values["provider"], values["account"])
    )
    contract = dict(registry[args.provider])
    contract.update(
        {
            "provider": args.provider,
            "state_key": (
                f"terraform/{prefix}/{values['workspace']}/terraform.tfstate"
                if contract["provisioner"] == "terraform"
                else None
            ),
            "inventory_key": f"inventory/{prefix}/{values['workspace']}.json",
            "run_key": f"runs/{prefix}/{values['workspace']}/{values['run_id']}.json",
        }
    )

    if args.github_output:
        output = os.environ.get("GITHUB_OUTPUT")
        if not output:
            raise SystemExit("--github-output requires GITHUB_OUTPUT")
        with Path(output).open("a", encoding="utf-8") as handle:
            for key, value in contract.items():
                handle.write(f"{key}={'' if value is None else value}\n")
    else:
        print(json.dumps(contract, sort_keys=True))


if __name__ == "__main__":
    try:
        main()
    except ValueError as exc:
        print(f"contract error: {exc}", file=sys.stderr)
        raise SystemExit(2) from exc
