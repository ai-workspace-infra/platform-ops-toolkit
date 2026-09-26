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
* ``fresh-*``: a new environment that an operator initializes by hand:
  leader, manual init/unseal, then one peer per dispatch (each unsealed and
  checked with ``raft list-peers`` before the next), quorum, monitoring and
  XConnect, then ``vault-service-verify``.
* ``migrate-*``: the existing vault.svc.plus node is checked read-only,
  converted in place to single-node Raft, snapshotted (with a restore drill),
  and the new nodes join it over XConnect one at a time. Leadership then moves
  to the new nodes, the service DNS moves last, and the old peer is removed
  only after the declared observation window. The new nodes are never
  initialized on this path. ``migrate-auto`` picks the next of these steps
  from live state (see auto_migration.py) and stops at every manual gate.

``one_node`` stages change exactly one peer per dispatch (the first declared
peer that has not joined); ``snapshot_first`` stages take an encrypted,
restore-drilled snapshot before they change anything.

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
        # Snapshot, restore drill in a disposable Raft Vault on the runner,
        # age encryption, upload, and a read-back check of the off-site copy.
        # The token comes from the backup credential login (snapshot role).
        "action": "snapshot",
        "next": (
            "The snapshot restored in a disposable Vault and the off-site copy reads back intact. "
            "Keep the age identity and unseal keys offline for a full restore."
        ),
    },
    "vault-service-verify": {
        "path": "any",
        "ssh": "new",
        # Final check of both paths: quorum on the declared nodes, monitoring
        # and the Gateway running, and the public service address answering
        # as this cluster.
        "requires": ["access", "raft-quorum", "monitoring-running", "gateway-running", "service-endpoint"],
        "next": "The service is verified. Migration: rekey, rotate and revoke the old root token by hand (M7).",
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
    "xconnect-gateway": {
        "path": "any",
        "ssh": "new",
        # Only SSH access: on the migration path the old node joins the new
        # cluster over this overlay, so the Gateway cannot wait for Raft.
        "requires": ["access"],
        "playbook": SHARED_PLAYBOOK,
        # identity creates the WireGuard key; the control plane then issues a
        # one-use invitation bound to it (xconnect_stage.py) before enrollment.
        "tags": ["xconnect-gateway-identity", "xconnect-gateway"],
        "confirms": ["gateway-running"],
        "secrets": ["xconnect"],
        "xconnect": "gateway",
        "next": (
            "Check the Gateway in the Zero portal, then enroll the other nodes with "
            "xconnect-one once it is enabled."
        ),
    },
    "xconnect-one": {
        "path": "any",
        # New peers, plus the existing vault.svc.plus node while
        # spec.migration is declared (M4): it reaches the new cluster only
        # through this overlay.
        "ssh": "cluster",
        "requires": ["access", "gateway-enrolled"],
        "playbook": SHARED_PLAYBOOK,
        "tags": ["xconnect-one"],
        "secrets": ["xconnect"],
        "xconnect": "one",
        "next": (
            "Record each node's overlay IP in the GitOps topology (and "
            "spec.migration.source.overlay_address for the existing node), then "
            "enroll the operator Mac with a one-use invitation."
        ),
    },
    "xconnect-operator-invite": {
        "path": "any",
        # SSH only to read the enrolled Gateway's public key.
        "ssh": "new",
        "requires": ["access", "gateway-enrolled"],
        # No host change: the runner issues a one-use invitation for the
        # operator device declared in GitOps and writes it straight to Vault
        # (create/update only); the operator reads it with their own login.
        "token": "xconnect",
        "secrets": ["xconnect"],
        "xconnect": "operator",
        "next": (
            "On the operator Mac, within 30 minutes: vault kv get -field=join_uri "
            "kv/CICD/shared/xconnect-operator-invite, then xconnect join with it."
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
        "requires": ["access", "leader-unsealed", "next-peer"],
        "playbook": SHARED_PLAYBOOK,
        "tags": ["vault-shared-peers"],
        "one_node": True,
        "confirms": ["selected-running"],
        "next": (
            "Unseal this peer by hand and confirm vault operator raft list-peers shows it as a voter. "
            "Then dispatch fresh-peers again for the next peer; after the last one, dispatch vault-raft-verify."
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
        # legacy-overlay: the converted node's Raft cluster_addr is written
        # into the Raft configuration, so it must already be the old node's
        # XConnect address (enroll it with xconnect-one first; that does not
        # touch Vault). The Raft path itself is verified before migrate-join.
        "requires": ["access", "legacy-unsealed", "legacy-report", "legacy-overlay"],
        "playbook": LEGACY_PLAYBOOK,
        "tags": ["vault-legacy-convert", "vault-single-raft"],
        "confirms": ["leader-running", "vault-port-guard"],
        "confirm": "CONVERT-VAULT-TO-RAFT",
        "next": (
            "Unseal the converted node with its existing key, check vault.svc.plus, "
            "then dispatch vault-snapshot (snapshot and restore drill). Roll back with migrate-rollback."
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
        # overlay-raft-path: XConnect connects the old cluster and the new
        # nodes (tcp 8200/8201 both ways) before anything joins.
        "requires": ["access", "legacy-raft", "no-foreign-cluster", "raft-overlay", "overlay-raft-path", "next-peer"],
        "playbook": SHARED_PLAYBOOK,
        "tags": ["vault-shared-peers"],
        "one_node": True,
        "snapshot_first": True,
        "confirms": ["selected-running"],
        "next": (
            "Unseal this node with the existing key and confirm vault operator raft list-peers shows it "
            "as a voter. Dispatch migrate-join again for the next node; after the last one, migrate-cutover."
        ),
    },
    "migrate-cutover": {
        "path": "migration",
        "ssh": "all",
        "requires": ["access", "raft-quorum"],
        "action": "cutover",
        "token": "raft-operator",
        "snapshot_first": True,
        # After the leadership transfer: the old node is a standby and the
        # whole cluster (new leader included) is healthy and agrees.
        "confirms": ["legacy-standby", "raft-quorum"],
        "confirm": "MOVE-VAULT-LEADER",
        "next": (
            "A new node leads and the cluster is healthy; the old node forwards to it. Now switch "
            "vault.svc.plus DNS to the new entry point (the last traffic change) and record "
            "spec.migration.observation.dns_switched_at in GitOps. Roll back inside the observation "
            "window by pointing the DNS back at the old node."
        ),
    },
    "migrate-remove": {
        "path": "migration",
        "ssh": "all",
        # Only after the service DNS moved and the observation window passed.
        "requires": ["access", "legacy-standby", "service-dns-moved", "observation-window"],
        "snapshot_first": True,
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
    "xconnect": "",
    "one_node": False,
    "snapshot_first": False,
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
    "gateway-identity",
    "gateway-running",
    "legacy-unsealed",
    "legacy-report",
    "legacy-overlay",
    "legacy-raft",
    "legacy-standby",
    "vault-port-guard",
    "next-peer",
    "selected-running",
    "overlay-raft-path",
    "raft-overlay",
    "service-dns-moved",
    "service-endpoint",
    "observation-window",
}
ACTIONS = {"", "snapshot", "cutover", "remove-legacy"}
TOKENS = {"", "snapshot", "raft-operator", "xconnect"}


def plan(stage: str, confirm: str = "", migration: bool | None = None, backup: bool | None = None) -> dict:
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
    if backup is False and (entry["snapshot_first"] or entry["action"] == "snapshot"):
        raise ValueError(
            f"stage {stage} takes an encrypted snapshot with a restore drill first; declare spec.backup"
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
        "xconnect": result["xconnect"],
        "one_node": "true" if result["one_node"] else "false",
        "snapshot_first": "true" if result["snapshot_first"] else "false",
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
    parser.add_argument("--backup", choices=["true", "false"], help="whether spec.backup is declared")
    parser.add_argument("--github-output", type=Path)
    args = parser.parse_args()
    migration = None if args.migration is None else args.migration == "true"
    backup = None if args.backup is None else args.backup == "true"
    try:
        result = plan(args.stage, args.confirm, migration, backup)
    except ValueError as error:
        print(f"::error::{error}", file=sys.stderr)
        raise SystemExit(1) from None
    if args.github_output:
        write_outputs(result, args.github_output)
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
