#!/usr/bin/env python3
"""Pick the next migrate-* step from live state (the migrate-auto stage).

Each migrate-auto dispatch probes the existing vault.svc.plus node and the
new nodes (token-free, see verify_vault_stage.py) and chooses exactly one
next step, or stops at a gate only a person may pass:

  PostgreSQL, unsealed           -> migrate-convert
  Raft, sealed                   -> stop: unseal the old node (existing key)
  Raft, active, new nodes empty  -> vault-snapshot, then migrate-join
  new nodes joined but sealed    -> stop: unseal them, confirm raft list-peers
  all unsealed, old node active  -> migrate-cutover
  old node standby, DNS on it    -> stop: move the service DNS
  old node standby, DNS moved    -> migrate-remove
  old node stopped and disabled  -> done (rekey/rotate/revoke by hand)

Rollback is never chosen automatically. The single MIGRATE-VAULT-AUTO
confirmation authorizes whichever destructive step is chosen; the chosen
stage's own requires/confirms gates still run before and after it.
"""

from __future__ import annotations

import argparse
import json
import socket
from pathlib import Path
from urllib.parse import urlparse

from render_inventory import validate
from stage_plan import STAGES, plan, write_outputs
from verify_vault_stage import (
    LEGACY_GROUP,
    VAULT_UNIT,
    active,
    health_of,
    new_nodes,
    probe,
    single,
    unsealed,
)


def blocked(message: str) -> dict:
    return {"stage": "", "blocked": message, "snapshot_first": False}


def chosen(stage: str, snapshot_first: bool = False) -> dict:
    return {"stage": stage, "blocked": "", "snapshot_first": snapshot_first}


def node_phase(state: dict) -> str:
    """empty (nothing to lose), sealed (joined, waiting for a key), unsealed."""
    health = health_of(state)
    if not health or health.get("initialized") is not True:
        return "empty"
    return "unsealed" if health.get("sealed") is False else "sealed"


def decide(contract: dict, probes: dict[str, dict], dns_on_legacy: bool, backup_declared: bool) -> dict:
    legacy = single(contract, LEGACY_GROUP, "legacy source node")
    source = probes[legacy["id"]]
    new = new_nodes(contract)
    if not source.get("reachable"):
        return blocked(f"{legacy['id']} is unreachable over the pinned SSH channel; fix access first.")

    source_running = source.get("units", {}).get(VAULT_UNIT) == "active"
    if not source_running and source.get("vault_enabled") == "disabled":
        if any(active(probes[node["id"]]) for node in new):
            return blocked(
                "Migration complete: the old node is retired and a new node leads. "
                "Now rekey, rotate and revoke the old root token by hand (M7), then remove spec.migration from GitOps."
            )
        return blocked(f"{legacy['id']} is retired but no new node is active; investigate before anything else.")
    if not health_of(source):
        return blocked(f"{legacy['id']}: Vault is not answering on its loopback listener; investigate.")

    storage = source.get("storage_type")
    if storage == "postgresql":
        if not unsealed(source):
            return blocked(f"{legacy['id']}: unseal the existing PostgreSQL-backed Vault first.")
        return chosen("migrate-convert")
    if storage != "raft":
        return blocked(f"{legacy['id']}: unsupported storage {storage!r}; stop and investigate.")
    if not unsealed(source):
        return blocked(f"{legacy['id']}: unseal the converted node with its existing key, then dispatch migrate-auto again.")

    phases = {node["id"]: node_phase(probes[node["id"]]) for node in new}
    if all(phase == "empty" for phase in phases.values()):
        if not active(source):
            return blocked(f"{legacy['id']} is not the active node; new nodes can only join an active leader.")
        if not backup_declared:
            return blocked("Declare spec.backup in the Vault service declaration: migrate-auto snapshots before new nodes join.")
        return chosen("migrate-join", snapshot_first=True)
    sealed = sorted(node_id for node_id, phase in phases.items() if phase == "sealed")
    if sealed:
        return blocked(
            f"Unseal {', '.join(sealed)} with the existing key, confirm vault operator raft list-peers "
            "shows every node as a voter, then dispatch migrate-auto again."
        )
    missing = sorted(node_id for node_id, phase in phases.items() if phase == "empty")
    if missing:
        return blocked(
            f"{', '.join(missing)} did not join the cluster; check overlay reachability to "
            f"{legacy['id']} and the peers' Vault logs before retrying."
        )

    if active(source):
        return chosen("migrate-cutover")
    if dns_on_legacy:
        return blocked("Leadership has moved. Point the service DNS at the new entry point, then dispatch migrate-auto again.")
    return chosen("migrate-remove")


def addresses(host: str) -> set[str]:
    try:
        return {item[4][0] for item in socket.getaddrinfo(host, 443, proto=socket.IPPROTO_TCP)}
    except OSError:
        return set()


def dns_points_at_legacy(service_host: str, legacy_address: str) -> bool:
    """Conservative: an unresolvable service name counts as still on the old node."""
    service = addresses(service_host)
    return not service or bool(service & addresses(legacy_address))


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--contract", type=Path, required=True)
    parser.add_argument("--key", type=Path, required=True)
    parser.add_argument("--known-hosts", type=Path, required=True)
    parser.add_argument("--vault-addr", required=True)
    parser.add_argument("--backup-config", default="{}")
    parser.add_argument("--gateway-state", default="")
    parser.add_argument("--github-output", type=Path)
    args = parser.parse_args()

    contract = validate(json.loads(args.contract.read_text(encoding="utf-8")))
    probes = {
        node["id"]: probe(node, args.key, args.known_hosts, args.gateway_state)
        for node in contract["spec"]["nodes"]
    }
    legacy = single(contract, LEGACY_GROUP, "legacy source node")
    service_host = urlparse(args.vault_addr).hostname or ""
    decision = decide(
        contract,
        probes,
        dns_on_legacy=dns_points_at_legacy(service_host, legacy["address"]),
        backup_declared=bool(json.loads(args.backup_config or "{}")),
    )

    if decision["stage"]:
        stage = decision["stage"]
        result = plan(stage, STAGES[stage].get("confirm", ""), migration=True)
        extra = {"blocked": "", "snapshot_first": "true" if decision["snapshot_first"] else "false"}
        if decision["snapshot_first"]:
            # The snapshot runs before the chosen stage and needs its own role.
            extra["token"] = "snapshot"
        print(f"migrate-auto: next step is {stage}" + (" (snapshot first)" if decision["snapshot_first"] else ""))
    else:
        result = None
        print(f"migrate-auto: stopping here. {decision['blocked']}")

    if args.github_output:
        if result is not None:
            write_outputs(result, args.github_output, extra)
        else:
            with args.github_output.open("a", encoding="utf-8") as stream:
                for name, value in {
                    "stage": "", "blocked": decision["blocked"], "snapshot_first": "false",
                    "token": "", "action": "", "needs_observability": "false",
                }.items():
                    stream.write(f"{name}={value}\n")


if __name__ == "__main__":
    main()
