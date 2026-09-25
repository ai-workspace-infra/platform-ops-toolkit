#!/usr/bin/env python3
"""Resolve non-secret Vault service and provider settings from reviewed GitOps."""

from __future__ import annotations

import argparse
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
