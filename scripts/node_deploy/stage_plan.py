#!/usr/bin/env python3
"""Provider-neutral stage plan for a Vault server NodeDeployment.

Each workflow dispatch runs exactly one stage. Manual Vault init/unseal can
span several dispatches, so ordering is enforced by checking live node state
(``requires``) at the start of every stage rather than by a ``needs`` chain.
Provider adapters only open and close SSH access; nothing here depends on
the cloud that created the nodes.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

PLAYBOOK = "deploy_vault_shared_services.yml"

# Order matches the reviewed rollout: preflight, leader, peers, quorum
# confirmation, monitoring, then XConnect Gateway and One.
STAGES: dict[str, dict] = {
    "node-preflight": {
        "requires": ["access"],
        "tags": [],
        "confirms": [],
        "secrets": [],
        "enabled": True,
        "next": "Run vault-shared-leader.",
    },
    "vault-shared-leader": {
        "requires": ["access", "no-foreign-cluster"],
        "tags": ["vault-shared-leader"],
        "confirms": ["leader-running"],
        "secrets": [],
        "enabled": True,
        "next": (
            "From a secured operator terminal, run vault operator init on the "
            "leader and unseal it. Then dispatch vault-shared-peers."
        ),
    },
    "vault-shared-peers": {
        "requires": ["access", "leader-unsealed"],
        "tags": ["vault-shared-peers"],
        "confirms": ["peers-running"],
        "secrets": [],
        "enabled": True,
        "next": (
            "Unseal each peer by hand, confirm vault operator raft list-peers "
            "shows every node as a voter, then dispatch vault-raft-verify."
        ),
    },
    "vault-raft-verify": {
        "requires": ["access", "raft-quorum"],
        "tags": [],
        "confirms": [],
        "secrets": [],
        "enabled": True,
        "next": "Dispatch node-process-metrics.",
    },
    "node-process-metrics": {
        "requires": ["access", "raft-quorum"],
        "tags": ["node-process-metrics"],
        "confirms": ["monitoring-running"],
        "secrets": ["observability"],
        "enabled": True,
        "next": "Dispatch xconnect-gateway once its prerequisites are in place.",
    },
    "xconnect-gateway": {
        "requires": ["access", "raft-quorum"],
        "tags": ["xconnect-gateway"],
        "confirms": [],
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
        "requires": ["access", "raft-quorum", "gateway-enrolled"],
        "tags": ["xconnect-one"],
        "confirms": [],
        "secrets": ["xconnect", "observability"],
        "enabled": False,
        "reason": "One enrollment needs the Gateway stage and one-use One invitations.",
        "next": (
            "Enroll the operator Mac with its own one-use invitation, verify the "
            "overlay IPs and internal DNS, then switch GitOps to xconnect-zero."
        ),
    },
}

CHECKS = {
    "access",
    "no-foreign-cluster",
    "leader-running",
    "leader-unsealed",
    "peers-running",
    "raft-quorum",
    "monitoring-running",
    "gateway-enrolled",
}


def plan(stage: str) -> dict:
    if stage not in STAGES:
        raise ValueError(f"unknown node stage {stage!r}; choose one of {list(STAGES)}")
    entry = STAGES[stage]
    if not entry["enabled"]:
        raise ValueError(f"stage {stage} is not available yet: {entry['reason']}")
    return {"stage": stage, "playbook": PLAYBOOK, **entry}


def write_outputs(result: dict, output: Path) -> None:
    with output.open("a", encoding="utf-8") as stream:
        stream.write(f"playbook={result['playbook']}\n")
        stream.write(f"tags={','.join(result['tags'])}\n")
        stream.write(f"requires={','.join(result['requires'])}\n")
        stream.write(f"confirms={','.join(result['confirms'])}\n")
        stream.write(f"needs_observability={'true' if 'observability' in result['secrets'] else 'false'}\n")
        stream.write(f"needs_xconnect={'true' if 'xconnect' in result['secrets'] else 'false'}\n")
        stream.write(f"next={result['next']}\n")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("stage")
    parser.add_argument("--github-output", type=Path)
    args = parser.parse_args()
    try:
        result = plan(args.stage)
    except ValueError as error:
        print(f"::error::{error}", file=sys.stderr)
        raise SystemExit(1) from None
    if args.github_output:
        write_outputs(result, args.github_output)
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
