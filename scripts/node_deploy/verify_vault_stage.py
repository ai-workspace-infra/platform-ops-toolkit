#!/usr/bin/env python3
"""Probe live nodes and enforce the manual Vault checkpoints between stages.

The probe reads only unauthenticated, non-secret state over the pinned SSH
channel: sudo availability, swap, Vault's loopback ``sys/health`` and
``sys/leader`` endpoints, and service unit states. It never needs a Vault
token, so GitHub Actions can gate stages without holding root tokens or
unseal shares. Operators still confirm ``vault operator raft list-peers``.
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
VAULT_UNIT = "vault"
MONITORING_UNITS = ("node-exporter", "process-exporter", "vector")
SAFE_ARGUMENT = re.compile(r"^[A-Za-z0-9_./-]*$")

REMOTE_PROBE = r"""
import json, subprocess, sys, urllib.error, urllib.request

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
units, gateway_state = sys.argv[1], sys.argv[2]
print(json.dumps({
    "sudo": run("sudo", "-n", "true").returncode == 0,
    "swap_kb": swap_kb,
    "health": api("/v1/sys/health?standbycode=200&sealedcode=200&uninitcode=200"),
    "leader": api("/v1/sys/leader"),
    "units": {unit: run("systemctl", "is-active", unit).stdout.strip() for unit in units.split(",") if unit},
    "gateway_state": bool(gateway_state) and run("sudo", "-n", "test", "-s", gateway_state).returncode == 0,
}))
"""


def probe(node: dict, key: Path, known_hosts: Path, gateway_state: str) -> dict:
    units = ",".join((VAULT_UNIT, *MONITORING_UNITS))
    if not SAFE_ARGUMENT.fullmatch(gateway_state):
        raise ValueError("gateway state path contains unsupported characters")
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
        "python3", "-", shlex.quote(units), shlex.quote(gateway_state),
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


def health_of(state: dict) -> dict:
    health = state.get("health")
    return health if isinstance(health, dict) and "initialized" in health else {}


def unsealed(state: dict) -> bool:
    health = health_of(state)
    return health.get("initialized") is True and health.get("sealed") is False


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


def single_leader(contract: dict) -> dict:
    leaders = members(contract, LEADER_GROUP)
    if len(leaders) != 1:
        raise ValueError("exactly one declared Vault leader is required")
    return leaders[0]


def check_running(nodes: list[dict], probes: dict[str, dict]) -> None:
    for node in nodes:
        state = probes[node["id"]]
        if not health_of(state):
            raise ValueError(f"{node['id']}: Vault is not answering on its loopback listener")
        if state.get("units", {}).get(VAULT_UNIT) != "active":
            raise ValueError(f"{node['id']}: the {VAULT_UNIT} service is not active")


def check_leader_unsealed(contract: dict, probes: dict[str, dict]) -> None:
    leader = single_leader(contract)
    if not unsealed(probes[leader["id"]]):
        raise ValueError(
            f"{leader['id']}: Vault leader must be initialized and unsealed by an operator before peers"
        )
    check_no_foreign_cluster(contract, probes)


def check_raft_quorum(contract: dict, probes: dict[str, dict]) -> None:
    nodes = contract["spec"]["nodes"]
    if len(nodes) % 2 == 0:
        raise ValueError("Raft needs an odd number of voters")
    private = {node.get("private_address") for node in nodes}
    clusters: set[str] = set()
    leader_addresses: set[str] = set()
    active = 0
    for node in nodes:
        state = probes[node["id"]]
        health = health_of(state)
        if not unsealed(state):
            raise ValueError(f"{node['id']}: Vault must be manually unsealed before this stage")
        cluster_id = health.get("cluster_id")
        if not isinstance(cluster_id, str) or not cluster_id:
            raise ValueError(f"{node['id']}: Vault cluster identity is missing")
        clusters.add(cluster_id)
        if health.get("standby") is False:
            active += 1
        leader = state.get("leader") if isinstance(state.get("leader"), dict) else {}
        address = leader.get("leader_cluster_address")
        if not isinstance(address, str) or not address:
            raise ValueError(f"{node['id']}: no Raft leader is visible from this node")
        leader_addresses.add(address)
    if len(clusters) != 1:
        raise ValueError("Vault nodes report different cluster IDs; they are not one Raft cluster")
    if active != 1:
        raise ValueError(f"Vault HA needs exactly one active node; found {active}")
    if len(leader_addresses) != 1:
        raise ValueError("Vault nodes disagree about the Raft leader")
    host = urlparse(next(iter(leader_addresses))).hostname
    if host not in private:
        raise ValueError("the Raft leader is not a declared node's private address")


def check_monitoring(nodes: list[dict], probes: dict[str, dict]) -> None:
    for node in nodes:
        units = probes[node["id"]].get("units", {})
        stopped = [unit for unit in MONITORING_UNITS if units.get(unit) != "active"]
        if stopped:
            raise ValueError(f"{node['id']}: monitoring units are not active: {', '.join(stopped)}")


def check_gateway_enrolled(contract: dict, probes: dict[str, dict]) -> None:
    gateways = members(contract, GATEWAY_GROUP)
    if len(gateways) != 1:
        raise ValueError("exactly one declared XConnect Gateway is required")
    if probes[gateways[0]["id"]].get("gateway_state") is not True:
        raise ValueError(f"{gateways[0]['id']}: XConnect Gateway enrollment state is missing")


def verify(contract: dict, checks: list[str], probes: dict[str, dict]) -> None:
    unknown = set(checks) - CHECKS
    if unknown:
        raise ValueError(f"unknown checks: {sorted(unknown)}")
    nodes = contract["spec"]["nodes"]
    for check in checks:
        if check == "access":
            check_access(nodes, probes)
        elif check == "no-foreign-cluster":
            check_no_foreign_cluster(contract, probes)
        elif check == "leader-running":
            check_running([single_leader(contract)], probes)
        elif check == "leader-unsealed":
            check_leader_unsealed(contract, probes)
        elif check == "peers-running":
            check_running(members(contract, PEER_GROUP), probes)
        elif check == "raft-quorum":
            check_raft_quorum(contract, probes)
        elif check == "monitoring-running":
            check_monitoring(nodes, probes)
        elif check == "gateway-enrolled":
            check_gateway_enrolled(contract, probes)


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
        "| Node | Vault | Cluster | sudo | swap | node-exporter | process-exporter | vector |",
        "| --- | --- | --- | --- | --- | --- | --- | --- |",
    ]
    for node in contract["spec"]["nodes"]:
        state = probes[node["id"]]
        cluster = str(health_of(state).get("cluster_id") or "")[:8] or "-"
        units = state.get("units", {})
        lines.append(
            f"| {node['id']} | {describe(state)} | {cluster} | {state.get('sudo', '-')} | "
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
    for attempt in range(max(args.attempts, 1)):
        if attempt:
            time.sleep(args.interval)
        probes = {
            node["id"]: probe(node, args.key, args.known_hosts, args.gateway_state)
            for node in contract["spec"]["nodes"]
        }
        try:
            verify(contract, checks, probes)
            error = None
            break
        except ValueError as failure:
            error = failure
    report = summary(contract, probes, args.title)
    print(report)
    step_summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if step_summary:
        with open(step_summary, "a", encoding="utf-8") as stream:
            stream.write(report + "\n")
    if error is not None:
        raise SystemExit(f"::error::{error}")
    print(f"Verified: {', '.join(checks) or 'state report only'}")


if __name__ == "__main__":
    main()
