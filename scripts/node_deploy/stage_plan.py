#!/usr/bin/env python3
"""Provider-neutral stage plan for a Vault server NodeDeployment.

Each workflow dispatch runs exactly one stage. Manual Vault init/unseal can
span several dispatches, so ordering is enforced by checking live node state
(``requires``) at the start of every stage rather than by a ``needs`` chain.
Provider adapters only open and close SSH access; nothing here depends on
the cloud that created the nodes.

Stage names are grouped by prefix so the dispatch dropdown reads in order:

* ``node-*`` / ``vault-*``: shared by both paths (preflight, monitoring,
  Raft verification, snapshot).
* ``fresh-*``: a new environment that an operator initializes by hand.
* ``migrate-*``: the existing vault.svc.plus node is converted in place to
  single-node Raft, the new nodes join it over XConnect, leadership moves to
  the new nodes and the old node is removed. The new nodes are never
  initialized on this path. ``migrate-auto`` picks the next of these steps
  from live state (see auto_migration.py) and stops at every manual gate.

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
# Converts the existing node in place, then imports
# deploy_vault_single_raft.yml to write the Raft config and start it; also
# owns rollback and retire. Lives in playbooks: this is host configuration.
LEGACY_PLAYBOOK = "deploy_vault_legacy_migration.yml"

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
        "next": "Fresh: dispatch fresh-leader. Migration: dispatch migrate-auto (or migrate-preflight).",
    },
    "vault-raft-verify": {
        "path": "any",
        "ssh": "cluster",
        "requires": ["access", "raft-quorum"],
        "next": "Take a snapshot with vault-snapshot.",
    },
    "vault-snapshot": {
        "path": "any",
        "ssh": "none",
        "requires": [],
        "action": "snapshot",
        "token": "snapshot",
        "next": "Keep the encrypted snapshot off-site; run a restore drill before migrating.",
    },
    "xconnect-gateway-frontend": {
        "path": "any",
        "ssh": "new",
        "requires": ["access"],
        "playbook": SHARED_PLAYBOOK,
        # Caddy on the Gateway node: TLS 443 for its own hostname, only
        # /xconnect forwarded to the Gateway Xray socket (playbooks role
        # vhosts/vault_gateway_frontend). Needed before the old node can
        # reach the overlay, so it does not wait for Raft quorum.
        "tags": ["vault-gateway-frontend"],
        "secrets": ["tls"],
        "next": (
            "Point the Gateway hostname's DNS at the Gateway node's public IP, "
            "then dispatch xconnect-gateway once it is enabled."
        ),
    },
    "fresh-leader": {
        "path": "fresh",
        "ssh": "new",
        "requires": ["access", "no-foreign-cluster"],
        "playbook": SHARED_PLAYBOOK,
        "tags": ["vault-shared-leader"],
        "confirms": ["leader-running"],
        "next": (
            "From a secured operator terminal, run vault operator init on the "
            "leader and unseal it. Then dispatch fresh-peers."
        ),
    },
    "fresh-peers": {
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
    "migrate-auto": {
        "path": "migration",
        "ssh": "all",
        "requires": ["access"],
        "auto": True,
        "confirm": "MIGRATE-VAULT-AUTO",
        "next": "Do the manual step shown above (if any), then dispatch migrate-auto again.",
    },
    "migrate-preflight": {
        "path": "migration",
        "ssh": "legacy",
        "requires": ["access", "legacy-unsealed", "legacy-report"],
        "next": "Dispatch migrate-convert with confirm=CONVERT-VAULT-TO-RAFT in a maintenance window.",
    },
    "migrate-convert": {
        "path": "migration",
        "ssh": "legacy",
        "requires": ["access", "legacy-unsealed", "legacy-overlay"],
        "playbook": LEGACY_PLAYBOOK,
        "tags": ["vault-legacy-convert", "vault-single-raft"],
        "confirms": ["leader-running", "vault-port-guard"],
        "confirm": "CONVERT-VAULT-TO-RAFT",
        "next": (
            "Unseal the converted node with its existing key, check vault.svc.plus, "
            "then dispatch vault-snapshot. Roll back with migrate-rollback."
        ),
    },
    "migrate-rollback": {
        "path": "migration",
        "ssh": "legacy",
        "requires": ["access"],
        "playbook": LEGACY_PLAYBOOK,
        "tags": ["vault-legacy-rollback"],
        "confirm": "ROLLBACK-VAULT-TO-POSTGRESQL",
        "next": "Unseal the restored PostgreSQL-backed Vault and investigate before retrying.",
    },
    "migrate-join": {
        "path": "migration",
        "ssh": "all",
        "requires": ["access", "legacy-raft", "new-nodes-empty"],
        "playbook": SHARED_PLAYBOOK,
        "tags": ["vault-shared-peers"],
        "confirms": ["peers-running"],
        "next": (
            "Unseal each new node with the existing key, confirm raft list-peers "
            "shows every node as a voter, then dispatch migrate-cutover."
        ),
    },
    "migrate-cutover": {
        "path": "migration",
        "ssh": "all",
        "requires": ["access", "raft-quorum"],
        "action": "cutover",
        "token": "raft-operator",
        "confirms": ["legacy-standby"],
        "confirm": "MOVE-VAULT-LEADER",
        "next": (
            "The old node now forwards to the new leader. Move vault.svc.plus DNS to "
            "the new entry point, then dispatch migrate-remove."
        ),
    },
    "migrate-remove": {
        "path": "migration",
        "ssh": "all",
        "requires": ["access", "legacy-standby"],
        "action": "remove-legacy",
        "token": "raft-operator",
        # The action removes the Raft peer via the Vault API; the playbook
        # tag then stops and disables the now-orphaned Vault service.
        "playbook": LEGACY_PLAYBOOK,
        "tags": ["vault-legacy-retire"],
        "confirms": ["raft-quorum-new"],
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
    "auto": False,
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
ACTIONS = {"", "snapshot", "cutover", "remove-legacy"}
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


def output_values(result: dict) -> dict[str, str]:
    return {
        "stage": result["stage"],
        "playbook": result["playbook"],
        "tags": ",".join(result["tags"]),
        "requires": ",".join(result["requires"]),
        "confirms": ",".join(result["confirms"]),
        "action": result["action"],
        "token": result["token"],
        "ssh": result["ssh"],
        "auto": "true" if result["auto"] else "false",
        "needs_observability": "true" if "observability" in result["secrets"] else "false",
        "needs_xconnect": "true" if "xconnect" in result["secrets"] else "false",
        "needs_tls": "true" if "tls" in result["secrets"] else "false",
        # Only the vault-legacy-{convert,rollback,retire} playbook tags read
        # this; it is harmless for every other stage/tag.
        "extra_vars": json.dumps({"vault_legacy_migration_confirm": result["confirm"]}),
        "next": result["next"],
    }


def write_outputs(result: dict, output: Path, extra: dict[str, str] | None = None) -> None:
    values = {**output_values(result), **(extra or {})}
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
