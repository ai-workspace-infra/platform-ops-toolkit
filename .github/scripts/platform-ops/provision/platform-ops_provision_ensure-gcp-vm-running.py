#!/usr/bin/env python3
"""Reconcile the runtime state of GitOps-declared GCP VMs.

Terraform treats an existing, stopped Spot VM as an in-sync resource.  That
is correct for state ownership but not sufficient for the following SSH
deployment stage.  This small, apply-only reconciliation starts only the
instances present in the rendered resource manifest and waits for GCP to
report RUNNING.  It never creates, replaces, or deletes an instance.
"""

from __future__ import annotations

import argparse
import json
import subprocess
import time
from pathlib import Path


def gcloud(*args: str) -> str:
    command = ["gcloud", *args, "--format=value(status)"]
    return subprocess.check_output(command, text=True, stderr=subprocess.STDOUT).strip()


def instance_specs(manifest: dict) -> list[tuple[str, str]]:
    specs: list[tuple[str, str]] = []
    for key in ("vault_nodes", "spot_vms"):
        for item in manifest.get(key, []) or []:
            name, zone = item.get("name"), item.get("zone")
            if not name or not zone:
                raise SystemExit(f"{key} entries require name and zone")
            specs.append((str(name), str(zone)))
    if not specs:
        raise SystemExit("resource manifest contains no GCP VMs")
    if len(set(specs)) != len(specs):
        raise SystemExit("resource manifest contains duplicate GCP VM identities")
    return specs


def reconcile(project: str, specs: list[tuple[str, str]], timeout: int, interval: int) -> None:
    deadline = time.monotonic() + timeout
    for name, zone in specs:
        status = gcloud("compute", "instances", "describe", name, "--project", project, "--zone", zone)
        print(f"GCP VM {name} ({zone}) status={status or 'unknown'}")
        if status in {"TERMINATED", "STOPPED", "SUSPENDED"}:
            print(f"Starting existing GCP VM {name}; no resource creation is requested.")
            subprocess.check_call(
                ["gcloud", "compute", "instances", "start", name, "--project", project, "--zone", zone, "--quiet"]
            )

    while True:
        pending = []
        for name, zone in specs:
            status = gcloud("compute", "instances", "describe", name, "--project", project, "--zone", zone)
            if status != "RUNNING":
                pending.append(f"{name}={status or 'unknown'}")
        if not pending:
            print("All declared GCP VMs are RUNNING.")
            return
        if time.monotonic() >= deadline:
            raise SystemExit(f"GCP VMs did not become RUNNING within {timeout}s: {', '.join(pending)}")
        print(f"Waiting for GCP VM runtime readiness: {', '.join(pending)}")
        time.sleep(interval)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--project", required=True)
    parser.add_argument("--timeout", type=int, default=300)
    parser.add_argument("--interval", type=int, default=5)
    args = parser.parse_args()
    if args.timeout < 1 or args.interval < 1:
        raise SystemExit("timeout and interval must be positive")
    document = json.loads(args.manifest.read_text(encoding="utf-8"))
    reconcile(args.project, instance_specs(document), args.timeout, args.interval)


if __name__ == "__main__":
    main()
