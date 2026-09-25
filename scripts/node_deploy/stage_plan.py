#!/usr/bin/env python3
"""Provider-neutral stage plan for a Vault server NodeDeployment.

Each workflow dispatch runs exactly one stage. Manual Vault init/unseal can
span several dispatches, so ordering is enforced by checking live node state
(``requires``) at the start of every stage rather than by a ``needs`` chain.
Provider adapters only open and close SSH access; nothing here depends on
the cloud that created the nodes.

Two paths share these stages:

* fresh: a new environment is initialized by an operator (leader, peers).
* migration: the existing vault.svc.plus node is converted in place to
  single-node Raft, the new nodes join it over XConnect, leadership moves to
  the new nodes and the old node is removed. The new nodes are never
  initialized on this path.

``ssh`` selects which node sets the stage opens access to: ``new`` (provider
adapter), ``legacy`` (the existing source node), ``all``, ``cluster`` (new
nodes, plus the source node while spec.migration is declared) or ``none``
(the stage only talks to the Vault API from the runner).
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

SHARED_PLAYBOOK = "deploy_vault_shared_services.yml"
SINGLE_PLAYBOOK = "deploy_vault_single_raft.yml"

STAGES: dict[str, dict] = {
    "node-preflight": {
        "path": "any",
        "ssh": "new",
        "requires": ["access"],
        "next": "Run node-process-metrics so the rollout is observable from the start.",
    },
    "node-process-metrics": {
        "path": "any",
        "ssh": "new",
        "requires": ["access"],
        "playbook": SHARED_PLAYBOOK,
        "tags": ["node-process-metrics"],
        "confirms": ["monitoring-running"],
        "secrets": ["observability"],
        "next": "Fresh: dispatch vault-shared-leader. Migration: dispatch legacy-preflight.",
    },
    "vault-shared-leader": {
        "path": "fresh",
        "ssh": "new",
        "requires": ["access", "no-foreign-cluster"],
        "playbook": SHARED_PLAYBOOK,
        "tags": ["vault-shared-leader"],
        "confirms": ["leader-running"],
        "next": (
            "From a secured operator terminal, run vault operator init on the "
            "leader and unseal it. Then dispatch vault-shared-peers."
        ),
    },
    "vault-shared-peers": {
        "path": "fresh",
        "ssh": "new",
        "requires": ["access", "leader-unsealed"],
        "playbook": SHARED_PLAYBOOK,
        "tags": ["vault-shared-peers"],
        "confirms": ["peers-running"],
        "next": (
            "Unseal each peer by hand, confirm vault operator raft list-peers "
            "shows every node as a voter, then dispatch vault-raft-verify."
        ),
    },
    "vault-raft-verify": {
        "path": "any",
        "ssh": "cluster",
        "requires": ["access", "raft-quorum"],
        "next": "Take a snapshot with vault-snapshot.",
    },
    "legacy-preflight": {
        "path": "migration",
        "ssh": "legacy",
        "requires": ["access", "legacy-unsealed", "legacy-report"],
        "next": "Dispatch legacy-convert-raft with confirm=CONVERT-VAULT-TO-RAFT in a maintenance window.",
    },
    "legacy-convert-raft": {
        "path": "migration",
        "ssh": "legacy",
        "requires": ["access", "legacy-unsealed", "legacy-overlay"],
        "action": "legacy-convert",
        "playbook": SINGLE_PLAYBOOK,
        "tags": ["vault-single-raft"],
        "confirms": ["leader-running", "vault-port-guard"],
        "confirm": "CONVERT-VAULT-TO-RAFT",
        "next": (
            "Unseal the converted node with its existing key, check vault.svc.plus, "
            "then dispatch vault-snapshot. Roll back with legacy-convert-rollback."
        ),
    },
    "legacy-convert-rollback": {
        "path": "migration",
        "ssh": "legacy",
        "requires": ["access"],
        "action": "legacy-rollback",
        "confirm": "ROLLBACK-VAULT-TO-POSTGRESQL",
        "next": "Unseal the restored PostgreSQL-backed Vault and investigate before retrying.",
    },
    "vault-snapshot": {
        "path": "any",
        "ssh": "none",
        "requires": [],
        "action": "snapshot",
        "token": "snapshot",
        "next": "Keep the encrypted snapshot off-site; run a restore drill before migrating.",
    },
    "vault-join-legacy": {
        "path": "migration",
        "ssh": "all",
        "requires": ["access", "legacy-raft", "new-nodes-empty"],
        "playbook": SHARED_PLAYBOOK,
        "tags": ["vault-shared-peers"],
        "confirms": ["peers-running"],
        "next": (
            "Unseal each new node with the existing key, confirm raft list-peers "
            "shows every node as a voter, then dispatch vault-cutover."
        ),
    },
    "vault-cutover": {
        "path": "migration",
        "ssh": "all",
        "requires": ["access", "raft-quorum"],
        "action": "cutover",
        "token": "raft-operator",
        "confirms": ["legacy-standby"],
        "confirm": "MOVE-VAULT-LEADER",
        "next": (
            "The old node now forwards to the new leader. Move vault.svc.plus DNS to "
            "the new entry point, then dispatch vault-remove-legacy."
        ),
    },
    "vault-remove-legacy": {
        "path": "migration",
        "ssh": "all",
        "requires": ["access", "legacy-standby"],
        "action": "remove-legacy",
        "confirms": ["raft-quorum-new"],
        "token": "raft-operator",
        "confirm": "REMOVE-LEGACY-VAULT-PEER",
        "next": "Rekey, rotate and revoke the old root token by hand (M7) before calling the migration done.",
    },
    "xconnect-gateway": {
        "path": "any",
        "ssh": "new",
        "requires": ["access"],
        "playbook": SHARED_PLAYBOOK,
        "tags": ["xconnect-gateway"],
        "secrets": ["xconnect"],
        "enabled": False,
        "reason": (
            "The shared Gateway needs a Caddy frontend for the service domain on "
            "the Gateway node, reviewed XConnect release artifacts, and a CI step "
            "that issues its one-use Zero invitation. None of these exist yet."
        ),
        "next": "Dispatch xconnect-one.",
    },
    "xconnect-one": {
        "path": "any",
        "ssh": "new",
        "requires": ["access", "gateway-enrolled"],
        "playbook": SHARED_PLAYBOOK,
        "tags": ["xconnect-one"],
        "secrets": ["xconnect", "observability"],
        "enabled": False,
        "reason": "One enrollment needs the Gateway stage and one-use One invitations.",
        "next": "Enroll the operator Mac, verify overlay IPs and internal DNS.",
    },
}

DEFAULTS = {
    "playbook": "",
    "tags": [],
    "confirms": [],
    "secrets": [],
    "action": "",
    "token": "",
    "confirm": "",
    "enabled": True,
}

CHECKS = {
    "access",
    "no-foreign-cluster",
    "leader-running",
    "leader-unsealed",
    "peers-running",
    "raft-quorum",
    "raft-quorum-new",
    "monitoring-running",
    "gateway-enrolled",
    "legacy-unsealed",
    "legacy-report",
    "legacy-overlay",
    "legacy-raft",
    "legacy-standby",
    "new-nodes-empty",
    "vault-port-guard",
}
ACTIONS = {"", "legacy-convert", "legacy-rollback", "snapshot", "cutover", "remove-legacy"}
TOKENS = {"", "snapshot", "raft-operator"}


def plan(stage: str, confirm: str = "", migration: bool | None = None) -> dict:
    if stage not in STAGES:
        raise ValueError(f"unknown node stage {stage!r}; choose one of {list(STAGES)}")
    entry = {**DEFAULTS, **STAGES[stage]}
    if not entry["enabled"]:
        raise ValueError(f"stage {stage} is not available yet: {entry['reason']}")
    if migration is not None:
        if entry["path"] == "migration" and not migration:
            raise ValueError(f"stage {stage} needs spec.migration in the Vault service declaration")
        if entry["path"] == "fresh" and migration:
            raise ValueError(
                f"stage {stage} would initialize a new cluster; a migration joins the existing one instead"
            )
    if entry["confirm"] and confirm != entry["confirm"]:
        raise ValueError(f"stage {stage} changes a live Vault; set confirm={entry['confirm']}")
    return {"stage": stage, **entry}


def write_outputs(result: dict, output: Path) -> None:
    values = {
        "playbook": result["playbook"],
        "tags": ",".join(result["tags"]),
        "requires": ",".join(result["requires"]),
        "confirms": ",".join(result["confirms"]),
        "action": result["action"],
        "token": result["token"],
        "ssh": result["ssh"],
        "needs_observability": "true" if "observability" in result["secrets"] else "false",
        "needs_xconnect": "true" if "xconnect" in result["secrets"] else "false",
        "next": result["next"],
    }
    with output.open("a", encoding="utf-8") as stream:
        for name, value in values.items():
            stream.write(f"{name}={value}\n")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("stage")
    parser.add_argument("--confirm", default="")
    parser.add_argument("--migration", choices=["true", "false"])
    parser.add_argument("--github-output", type=Path)
    args = parser.parse_args()
    migration = None if args.migration is None else args.migration == "true"
    try:
        result = plan(args.stage, args.confirm, migration)
    except ValueError as error:
        print(f"::error::{error}", file=sys.stderr)
        raise SystemExit(1) from None
    if args.github_output:
        write_outputs(result, args.github_output)
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
