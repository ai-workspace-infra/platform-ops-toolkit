#!/usr/bin/env python3
"""Probe live nodes and enforce the manual Vault checkpoints between stages.

The probe reads only unauthenticated, non-secret state over the pinned SSH
channel: sudo availability, swap, free disk, Vault's loopback ``sys/health``,
``sys/leader`` and ``sys/seal-status`` endpoints, listening sockets, the
Vault port guard, and service unit states. It never needs a Vault token, so
GitHub Actions can gate stages without holding root tokens or unseal shares.
Operators still confirm ``vault operator raft list-peers``.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shlex
import subprocess
import time
from pathlib import Path
from urllib.parse import urlparse

from render_inventory import validate
from stage_plan import CHECKS

LEADER_GROUP = "vault_shared_leader"
PEER_GROUP = "vault_shared_peers"
GATEWAY_GROUP = "xconnect_gateway"
LEGACY_GROUP = "vault_legacy_source"
VAULT_UNIT = "vault"
MONITORING_UNITS = ("node-exporter", "process-exporter", "vector")
VAULT_PORTS = (8200, 8201)
LOOPBACK = {"127.0.0.1", "::1", "localhost"}
GUARD_TABLE = "vault_port_guard"
INIT_FILE = "/etc/vault.d/vault_init.json"
MIN_FREE_MB = 1024
SAFE_ARGUMENT = re.compile(r"^[A-Za-z0-9_./-]*$")

REMOTE_PROBE = r"""
import json, os, subprocess, sys, urllib.error, urllib.request

def api(path):
    try:
        with urllib.request.urlopen("http://127.0.0.1:8200" + path, timeout=8) as response:
            return json.load(response)
    except urllib.error.HTTPError as error:
        try:
            return json.load(error)
        except ValueError:
            return {"errors": ["HTTP %d" % error.code]}
    except (OSError, ValueError):
        return None

def run(*argv):
    return subprocess.run(argv, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, universal_newlines=True)

swap_kb = 0
with open("/proc/swaps") as swaps:
    for line in swaps.readlines()[1:]:
        fields = line.split()
        if len(fields) >= 3 and fields[2].isdigit():
            swap_kb += int(fields[2])
units, gateway_state, init_file, guard_table = sys.argv[1:5]
listeners = []
for line in run("ss", "-Hltn").stdout.splitlines():
    fields = line.split()
    if len(fields) >= 4:
        address, _, port = fields[3].rpartition(":")
        if port in ("8200", "8201"):
            listeners.append({"address": address.strip("[]"), "port": int(port)})
disk = os.statvfs("/")
seal = api("/v1/sys/seal-status") or {}
print(json.dumps({
    "sudo": run("sudo", "-n", "true").returncode == 0,
    "swap_kb": swap_kb,
    "free_mb": disk.f_bavail * disk.f_frsize // 1048576,
    "health": api("/v1/sys/health?standbycode=200&sealedcode=200&uninitcode=200"),
    "leader": api("/v1/sys/leader"),
    "storage_type": seal.get("storage_type"),
    "version": seal.get("version"),
    "units": {unit: run("systemctl", "is-active", unit).stdout.strip() for unit in units.split(",") if unit},
    "gateway_state": bool(gateway_state) and run("sudo", "-n", "test", "-s", gateway_state).returncode == 0,
    "init_file": bool(init_file) and run("sudo", "-n", "test", "-e", init_file).returncode == 0,
    "port_guard": run("sudo", "-n", "nft", "list", "table", "inet", guard_table).returncode == 0,
    "listeners": listeners,
}))
"""


def probe(node: dict, key: Path, known_hosts: Path, gateway_state: str) -> dict:
    units = ",".join((VAULT_UNIT, *MONITORING_UNITS))
    init_file = INIT_FILE if LEGACY_GROUP in node.get("groups", []) else ""
    for value in (gateway_state, init_file):
        if not SAFE_ARGUMENT.fullmatch(value):
            raise ValueError("probe path contains unsupported characters")
    command = [
        "ssh", "-i", str(key),
        "-o", "IdentitiesOnly=yes",
        "-o", "BatchMode=yes",
        "-o", "ConnectTimeout=12",
        "-o", "StrictHostKeyChecking=yes",
        "-o", f"UserKnownHostsFile={known_hosts}",
        "-o", "HostKeyAlgorithms=ssh-ed25519",
        "-p", str(node.get("ssh_port", 22)),
        f"{node['ssh_user']}@{node['address']}",
        "python3", "-",
        *(shlex.quote(value) for value in (units, gateway_state, init_file, GUARD_TABLE)),
    ]
    try:
        result = subprocess.run(
            command, input=REMOTE_PROBE, capture_output=True, text=True, timeout=40, check=False
        )
    except subprocess.TimeoutExpired:
        return {"reachable": False}
    if result.returncode != 0:
        return {"reachable": False}
    try:
        state = json.loads(result.stdout.strip().splitlines()[-1])
    except (IndexError, json.JSONDecodeError):
        return {"reachable": False}
    if not isinstance(state, dict):
        return {"reachable": False}
    state["reachable"] = True
    return state


def members(contract: dict, group: str) -> list[dict]:
    return [node for node in contract["spec"]["nodes"] if group in node.get("groups", [])]


def new_nodes(contract: dict) -> list[dict]:
    return [node for node in contract["spec"]["nodes"] if LEGACY_GROUP not in node.get("groups", [])]


def health_of(state: dict) -> dict:
    health = state.get("health")
    return health if isinstance(health, dict) and "initialized" in health else {}


def unsealed(state: dict) -> bool:
    health = health_of(state)
    return health.get("initialized") is True and health.get("sealed") is False


def active(state: dict) -> bool:
    return unsealed(state) and health_of(state).get("standby") is False


def single(contract: dict, group: str, label: str) -> dict:
    nodes = members(contract, group)
    if len(nodes) != 1:
        raise ValueError(f"exactly one declared {label} is required")
    return nodes[0]


def check_access(nodes: list[dict], probes: dict[str, dict]) -> None:
    for node in nodes:
        state = probes[node["id"]]
        if not state.get("reachable"):
            raise ValueError(f"{node['id']}: SSH probe failed over the pinned host key")
        if state.get("sudo") is not True:
            raise ValueError(f"{node['id']}: non-interactive sudo is unavailable for the short-lived login")
        if state.get("swap_kb") != 0:
            raise ValueError(f"{node['id']}: swap is enabled; Vault Raft nodes must run without swap")


def check_no_foreign_cluster(contract: dict, probes: dict[str, dict]) -> None:
    clusters = {
        health_of(probes[node["id"]]).get("cluster_id")
        for node in contract["spec"]["nodes"]
        if unsealed(probes[node["id"]])
    }
    clusters.discard(None)
    if len(clusters) > 1:
        raise ValueError("unsealed nodes report different Vault cluster IDs; stop and investigate")
    leaders = members(contract, LEADER_GROUP)
    leader_initialized = bool(leaders) and health_of(probes[leaders[0]["id"]]).get("initialized") is True
    for node in members(contract, PEER_GROUP):
        if unsealed(probes[node["id"]]) and not leader_initialized:
            raise ValueError(f"{node['id']}: peer is unsealed while the leader is uninitialized")


def check_running(nodes: list[dict], probes: dict[str, dict]) -> None:
    for node in nodes:
        state = probes[node["id"]]
        if not health_of(state):
            raise ValueError(f"{node['id']}: Vault is not answering on its loopback listener")
        if state.get("units", {}).get(VAULT_UNIT) != "active":
            raise ValueError(f"{node['id']}: the {VAULT_UNIT} service is not active")


def check_leader_unsealed(contract: dict, probes: dict[str, dict]) -> None:
    leader = single(contract, LEADER_GROUP, "Vault leader")
    if not unsealed(probes[leader["id"]]):
        raise ValueError(
            f"{leader['id']}: Vault leader must be initialized and unsealed by an operator before peers"
        )
    check_no_foreign_cluster(contract, probes)


def check_raft_quorum(contract: dict, probes: dict[str, dict]) -> None:
    nodes = contract["spec"]["nodes"]
    addresses = {node.get("private_address") for node in nodes} | {node.get("overlay_address") for node in nodes}
    clusters: set[str] = set()
    leader_addresses: set[str] = set()
    active_nodes = 0
    for node in nodes:
        state = probes[node["id"]]
        health = health_of(state)
        if not unsealed(state):
            raise ValueError(f"{node['id']}: Vault must be manually unsealed before this stage")
        if state.get("storage_type") not in (None, "raft"):
            raise ValueError(f"{node['id']}: storage is {state.get('storage_type')}, not Raft")
        cluster_id = health.get("cluster_id")
        if not isinstance(cluster_id, str) or not cluster_id:
            raise ValueError(f"{node['id']}: Vault cluster identity is missing")
        clusters.add(cluster_id)
        if health.get("standby") is False:
            active_nodes += 1
        leader = state.get("leader") if isinstance(state.get("leader"), dict) else {}
        address = leader.get("leader_cluster_address")
        if not isinstance(address, str) or not address:
            raise ValueError(f"{node['id']}: no Raft leader is visible from this node")
        leader_addresses.add(address)
    if len(clusters) != 1:
        raise ValueError("Vault nodes report different cluster IDs; they are not one Raft cluster")
    if active_nodes != 1:
        raise ValueError(f"Vault HA needs exactly one active node; found {active_nodes}")
    if len(leader_addresses) != 1:
        raise ValueError("Vault nodes disagree about the Raft leader")
    host = urlparse(next(iter(leader_addresses))).hostname
    if host not in addresses:
        raise ValueError("the Raft leader is not a declared node's private or overlay address")


def check_monitoring(nodes: list[dict], probes: dict[str, dict]) -> None:
    for node in nodes:
        units = probes[node["id"]].get("units", {})
        stopped = [unit for unit in MONITORING_UNITS if units.get(unit) != "active"]
        if stopped:
            raise ValueError(f"{node['id']}: monitoring units are not active: {', '.join(stopped)}")


def check_gateway_enrolled(contract: dict, probes: dict[str, dict]) -> None:
    gateway = single(contract, GATEWAY_GROUP, "XConnect Gateway")
    if probes[gateway["id"]].get("gateway_state") is not True:
        raise ValueError(f"{gateway['id']}: XConnect Gateway enrollment state is missing")


def check_legacy_unsealed(contract: dict, probes: dict[str, dict]) -> None:
    legacy = single(contract, LEGACY_GROUP, "legacy source node")
    if not unsealed(probes[legacy["id"]]):
        raise ValueError(f"{legacy['id']}: the existing Vault must be initialized and unsealed")


def check_legacy_report(contract: dict, probes: dict[str, dict]) -> list[str]:
    legacy = single(contract, LEGACY_GROUP, "legacy source node")
    state = probes[legacy["id"]]
    free_mb = state.get("free_mb")
    if not isinstance(free_mb, int) or free_mb < MIN_FREE_MB:
        raise ValueError(f"{legacy['id']}: less than {MIN_FREE_MB} MiB free for the Raft data and backup")
    warnings = []
    if state.get("init_file"):
        warnings.append(
            f"{legacy['id']}: {INIT_FILE} (unseal key and root token) is on disk; "
            "rekey and revoke the root token after the migration"
        )
    storage = state.get("storage_type")
    if storage not in ("postgresql", "raft"):
        raise ValueError(f"{legacy['id']}: unsupported source storage {storage!r}")
    return warnings


def check_legacy_overlay(contract: dict) -> None:
    legacy = single(contract, LEGACY_GROUP, "legacy source node")
    overlay = legacy.get("overlay_address")
    if not overlay or legacy.get("private_address") != overlay:
        raise ValueError(
            f"{legacy['id']}: declare its XConnect overlay address first; Raft must never use a public address"
        )


def check_legacy_raft(contract: dict, probes: dict[str, dict]) -> None:
    legacy = single(contract, LEGACY_GROUP, "legacy source node")
    state = probes[legacy["id"]]
    if state.get("storage_type") != "raft":
        raise ValueError(f"{legacy['id']}: convert the existing Vault to Raft (legacy-convert-raft) first")
    if not active(state):
        raise ValueError(f"{legacy['id']}: the existing Vault must be unsealed and active before new nodes join")


def check_legacy_standby(contract: dict, probes: dict[str, dict]) -> None:
    legacy = single(contract, LEGACY_GROUP, "legacy source node")
    if not unsealed(probes[legacy["id"]]) or health_of(probes[legacy["id"]]).get("standby") is not True:
        raise ValueError(f"{legacy['id']}: the old node is still active; leadership did not move")
    if not any(active(probes[node["id"]]) for node in new_nodes(contract)):
        raise ValueError("no new node is active after the leadership transfer")


def check_new_nodes_empty(contract: dict, probes: dict[str, dict]) -> None:
    for node in new_nodes(contract):
        health = health_of(probes[node["id"]])
        if health.get("initialized") is True:
            raise ValueError(f"{node['id']}: already holds Vault data; a migration target must start empty")


def check_port_guard(contract: dict, probes: dict[str, dict]) -> None:
    for node in members(contract, LEGACY_GROUP):
        state = probes[node["id"]]
        allowed = LOOPBACK | {node.get("overlay_address")}
        exposed = [
            listener for listener in state.get("listeners", [])
            if listener.get("address") not in allowed
        ]
        if exposed and state.get("port_guard") is not True:
            raise ValueError(
                f"{node['id']}: Vault listens beyond loopback and overlay without the {GUARD_TABLE} firewall table"
            )


def verify(contract: dict, checks: list[str], probes: dict[str, dict]) -> list[str]:
    unknown = set(checks) - CHECKS
    if unknown:
        raise ValueError(f"unknown checks: {sorted(unknown)}")
    nodes = contract["spec"]["nodes"]
    warnings: list[str] = []
    for check in checks:
        if check == "access":
            check_access(nodes, probes)
        elif check == "no-foreign-cluster":
            check_no_foreign_cluster(contract, probes)
        elif check == "leader-running":
            check_running([single(contract, LEADER_GROUP, "Vault leader")], probes)
        elif check == "leader-unsealed":
            check_leader_unsealed(contract, probes)
        elif check == "peers-running":
            check_running(members(contract, PEER_GROUP), probes)
        elif check == "raft-quorum":
            check_raft_quorum(contract, probes)
        elif check == "raft-quorum-new":
            remaining = {**contract, "spec": {**contract["spec"], "nodes": new_nodes(contract)}}
            check_raft_quorum(remaining, probes)
        elif check == "monitoring-running":
            check_monitoring(new_nodes(contract), probes)
        elif check == "gateway-enrolled":
            check_gateway_enrolled(contract, probes)
        elif check == "legacy-unsealed":
            check_legacy_unsealed(contract, probes)
        elif check == "legacy-report":
            warnings.extend(check_legacy_report(contract, probes))
        elif check == "legacy-overlay":
            check_legacy_overlay(contract)
        elif check == "legacy-raft":
            check_legacy_raft(contract, probes)
        elif check == "legacy-standby":
            check_legacy_standby(contract, probes)
        elif check == "new-nodes-empty":
            check_new_nodes_empty(contract, probes)
        elif check == "vault-port-guard":
            check_port_guard(contract, probes)
    return warnings


def describe(state: dict) -> str:
    if not state.get("reachable"):
        return "unreachable"
    health = health_of(state)
    if not health:
        return "not running"
    if health.get("initialized") is not True:
        return "uninitialized"
    if health.get("sealed") is not False:
        return "sealed"
    return "active" if health.get("standby") is False else "standby"


def summary(contract: dict, probes: dict[str, dict], title: str) -> str:
    lines = [
        f"### {title}",
        "",
        "| Node | Vault | Storage | Version | Cluster | sudo | swap | node-exporter | process-exporter | vector |",
        "| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |",
    ]
    for node in contract["spec"]["nodes"]:
        state = probes[node["id"]]
        cluster = str(health_of(state).get("cluster_id") or "")[:8] or "-"
        units = state.get("units", {})
        lines.append(
            f"| {node['id']} | {describe(state)} | {state.get('storage_type') or '-'} | "
            f"{state.get('version') or '-'} | {cluster} | {state.get('sudo', '-')} | "
            f"{state.get('swap_kb', '-')} | "
            + " | ".join(units.get(unit, "-") or "-" for unit in MONITORING_UNITS)
            + " |"
        )
    return "\n".join(lines) + "\n"


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--contract", type=Path, required=True)
    parser.add_argument("--key", type=Path, required=True)
    parser.add_argument("--known-hosts", type=Path, required=True)
    parser.add_argument("--checks", default="", help="comma-separated checks; empty only reports state")
    parser.add_argument("--attempts", type=int, default=1)
    parser.add_argument("--interval", type=int, default=15)
    parser.add_argument("--gateway-state", default="")
    parser.add_argument("--title", default="Vault node state")
    args = parser.parse_args()
    contract = validate(json.loads(args.contract.read_text(encoding="utf-8")))
    checks = [check for check in args.checks.split(",") if check]
    error: ValueError | None = None
    warnings: list[str] = []
    for attempt in range(max(args.attempts, 1)):
        if attempt:
            time.sleep(args.interval)
        probes = {
            node["id"]: probe(node, args.key, args.known_hosts, args.gateway_state)
            for node in contract["spec"]["nodes"]
        }
        try:
            warnings = verify(contract, checks, probes)
            error = None
            break
        except ValueError as failure:
            error = failure
    report = summary(contract, probes, args.title)
    report += "".join(f"\n> ⚠️ {warning}\n" for warning in warnings)
    print(report)
    for warning in warnings:
        print(f"::warning::{warning}")
    step_summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if step_summary:
        with open(step_summary, "a", encoding="utf-8") as stream:
            stream.write(report + "\n")
    if error is not None:
        raise SystemExit(f"::error::{error}")
    print(f"Verified: {', '.join(checks) or 'state report only'}")


if __name__ == "__main__":
    main()
