#!/usr/bin/env python3
"""Resolve non-secret Vault service and provider settings from reviewed GitOps."""

from __future__ import annotations

import argparse
import json
import re
from pathlib import Path

import yaml


IDENTIFIER = re.compile(r"^[a-zA-Z0-9][a-zA-Z0-9._-]{0,127}$")
KV_PATH = re.compile(r"^kv/data/[a-zA-Z0-9/_-]+$")


def checked_path(root: Path, value: str) -> Path:
    path = Path(value)
    if path.is_absolute() or ".." in path.parts or not path.parts:
        raise ValueError("GitOps path must be relative and remain within the checkout")
    resolved = (root / path).resolve()
    if not resolved.is_relative_to(root.resolve()):
        raise ValueError("GitOps path escapes the reviewed checkout")
    return resolved


SSH_USER = re.compile(r"^[a-z_][a-z0-9_-]{0,31}$")
HOST_KEY = re.compile(r"^AAAAC3NzaC1lZDI1NTE5[A-Za-z0-9+/]+={0,2}$")
SIGN_PATH = re.compile(r"^[a-z0-9-]+/sign/[a-z0-9-]+$")
AGE_RECIPIENT = re.compile(r"^age1[0-9a-z]{58}$")
S3_URL = re.compile(r"^s3://[a-z0-9.-]+(/[A-Za-z0-9._/-]*)?$")
HTTPS_URL = re.compile(r"^https://[A-Za-z0-9.-]+(:[0-9]+)?(/[A-Za-z0-9._/-]*)?$")


def resolve_migration(service: dict, environment: str, vault_addr: str) -> dict[str, str]:
    """Validate spec.migration (the existing node being moved) if declared."""
    migration = service["spec"].get("migration")
    if not migration:
        return {"migration": "false", "legacy_config": "{}", "raft_operator_role": ""}
    source = migration["source"]
    ssh_ca = migration["ssh_ca"]
    if not IDENTIFIER.fullmatch(str(source.get("id", ""))):
        raise ValueError("invalid migration source id")
    if source["id"] in {node["id"] for node in service["spec"].get("nodes", [])}:
        raise ValueError("the migration source must not also be a declared new node")
    if not SSH_USER.fullmatch(str(source.get("ssh_user", ""))):
        raise ValueError("invalid migration source ssh_user")
    if not HOST_KEY.fullmatch(str(source.get("ssh_host_ed25519", ""))):
        raise ValueError("migration source needs a pinned Ed25519 host key")
    if not IDENTIFIER.fullmatch(str(ssh_ca.get("role", ""))) or not SIGN_PATH.fullmatch(str(ssh_ca.get("sign_path", ""))):
        raise ValueError("migration ssh_ca needs a JWT role and an SSH sign path")
    raft_operator_role = str(service["spec"]["automation"].get("raft_operator_role", ""))
    if not IDENTIFIER.fullmatch(raft_operator_role):
        raise ValueError("a migration needs automation.raft_operator_role")
    if migration.get("raft_network", "private") not in {"private", "overlay"}:
        raise ValueError("migration.raft_network must be private or overlay")
    config = {
        "environment": environment,
        "vault_addr": vault_addr,
        "id": source["id"],
        "ssh_user": source["ssh_user"],
        "ssh_role": ssh_ca["role"],
        "sign_path": ssh_ca["sign_path"],
        "overlay_interface": str(migration.get("overlay_interface", "xconone0")),
    }
    if not re.fullmatch(r"[A-Za-z0-9_.-]{1,15}", config["overlay_interface"]):
        raise ValueError("invalid migration overlay_interface")
    return {
        "migration": "true",
        "legacy_config": json.dumps(config, separators=(",", ":"), sort_keys=True),
        "raft_operator_role": raft_operator_role,
    }


def resolve_backup(service: dict, environment: str) -> dict[str, str]:
    """Validate spec.backup (encrypted off-site Raft snapshots) if declared."""
    backup = service["spec"].get("backup")
    if not backup:
        return {"backup_config": "{}", "snapshot_role": ""}
    role = str(backup.get("snapshot_role", ""))
    if not IDENTIFIER.fullmatch(role):
        raise ValueError("invalid backup.snapshot_role")
    if not AGE_RECIPIENT.fullmatch(str(backup.get("age_recipient", ""))):
        raise ValueError("backup.age_recipient must be an age public key")
    if not S3_URL.fullmatch(str(backup.get("destination", ""))):
        raise ValueError("backup.destination must be s3://bucket/prefix")
    endpoint = str(backup.get("endpoint", ""))
    if endpoint and not HTTPS_URL.fullmatch(endpoint):
        raise ValueError("backup.endpoint must be an https URL")
    credentials = str(backup.get("credentials_path", ""))
    if not KV_PATH.fullmatch(credentials) or f"/{environment}/" not in credentials:
        raise ValueError("backup.credentials_path must be a KV path in this environment")
    config = {
        "age_recipient": backup["age_recipient"],
        "destination": backup["destination"],
        "endpoint": endpoint,
        "region": str(backup.get("region", "us-east-1")),
        "credentials_path": credentials,
    }
    return {"backup_config": json.dumps(config, separators=(",", ":"), sort_keys=True), "snapshot_role": role}


def resolve(service: dict, provider: dict, provider_name: str) -> dict[str, str]:
    if service.get("kind") != "VaultServerDeployment":
        raise ValueError("expected VaultServerDeployment service declaration")
    environment = service.get("metadata", {}).get("environment")
    if not isinstance(environment, str) or not IDENTIFIER.fullmatch(environment):
        raise ValueError("invalid Vault service environment")
    if provider_name != "gcp-cloud" or provider.get("kind") != "GCPWorkloadNamespace":
        raise ValueError("no reviewed provider adapter for this declaration")
    if provider.get("metadata", {}).get("environment") != environment:
        raise ValueError("provider manifest belongs to another environment")
    provider_spec = provider["spec"]
    automation = service["spec"]["automation"]
    values = {
        "environment": environment,
        "github_environment": automation["github_environment"],
        "vault_addr": automation["vault_addr"],
        "runtime_identity_path": automation["runtime_identity_path"],
        "monitoring_secret_path": automation["monitoring_secret_path"],
        "xconnect_secret_path": automation["xconnect_secret_path"],
        "node_role": automation["node_role"],
        "monitoring_role": automation["monitoring_role"],
        "xconnect_role": automation["xconnect_role"],
        "account_id": provider_spec["gcp_account_id"],
        "project_id": provider_spec["project_id"],
        "network_name": provider_spec["network_name"],
        "ssh_access_mode": provider_spec["ssh_access_mode"],
        "xconnect_topology": service["spec"]["access"]["xconnect_topology"],
    }
    for name, value in values.items():
        if not isinstance(value, str) or not value or "\n" in value or "\r" in value:
            raise ValueError(f"invalid GitOps automation field: {name}")
    for name in ("environment", "github_environment", "account_id", "project_id", "network_name", "node_role", "monitoring_role", "xconnect_role"):
        if not IDENTIFIER.fullmatch(values[name]):
            raise ValueError(f"invalid GitOps identifier: {name}")
    for name in ("runtime_identity_path", "monitoring_secret_path", "xconnect_secret_path"):
        if not KV_PATH.fullmatch(values[name]) or "//" in values[name]:
            raise ValueError(f"invalid Vault KV path: {name}")
    if f"/{environment}/" not in values["runtime_identity_path"] or f"/{environment}/" not in values["xconnect_secret_path"]:
        raise ValueError("runtime identity and XConnect KV paths must match the service environment")
    if values["vault_addr"] != f"https://{service['spec']['service_domain']}":
        raise ValueError("Vault JWT endpoint must match the declared service domain")
    if values["ssh_access_mode"] not in {service["spec"]["access"]["bootstrap"], service["spec"]["access"]["steady_state"]}:
        raise ValueError("provider SSH mode is not declared by the Vault service")
    values.update(resolve_migration(service, environment, values["vault_addr"]))
    values.update(resolve_backup(service, environment))
    # Only the provider adapter reads this blob; the generic stage runner
    # forwards it without interpreting cloud-specific fields.
    values["provider_config"] = json.dumps(
        {
            "provider": provider_name,
            "environment": environment,
            "vault_addr": values["vault_addr"],
            "node_role": values["node_role"],
            "runtime_identity_path": values["runtime_identity_path"],
            "account_id": values["account_id"],
            "project_id": values["project_id"],
            "network_name": values["network_name"],
        },
        separators=(",", ":"),
        sort_keys=True,
    )
    return values


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--gitops-root", type=Path, required=True)
    parser.add_argument("--service-manifest", required=True)
    parser.add_argument("--provider-manifest", required=True)
    parser.add_argument("--provider", required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    root = args.gitops_root.resolve()
    service = yaml.safe_load(checked_path(root, args.service_manifest).read_text(encoding="utf-8"))
    provider = yaml.safe_load(checked_path(root, args.provider_manifest).read_text(encoding="utf-8"))
    values = resolve(service, provider, args.provider)
    checked_path(root, values["xconnect_topology"])
    with args.output.open("a", encoding="utf-8") as stream:
        for name, value in values.items():
            stream.write(f"{name}={value}\n")
    print(f"Resolved Vault service {service['metadata']['name']} in {values['environment']} using {args.provider}")


if __name__ == "__main__":
    main()
