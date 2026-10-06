#!/usr/bin/env python3
"""Resolve an input-selected deployment from GitOps without environment mappings."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import re

import yaml


PROVIDERS = {"aws", "gcp", "vps", "akamai-cloud", "existing"}
OPERATIONS = {"plan", "apply", "provision", "stage", "activate"}
NAME = re.compile(r"[a-z][a-z0-9-]*\Z")


def resource_adapter(contract):
    """Identify the resource format, rather than choosing the deployment cloud."""
    renderer = contract.get("renderer", "")
    if renderer == "cmdb/inventory":
        return "existing"
    for directory, provider in (
        ("aws-cloud", "aws"), ("gcp-cloud", "gcp"),
        ("vultr-cloud", "vps"), ("vps-cloud", "vps"),
        ("akamai-cloud", "akamai-cloud"),
    ):
        if directory in Path(renderer).parts:
            return provider
    raise ValueError(f"unsupported resource renderer: {renderer}")


def resolve(root: Path, environment: str, profile: str, provider: str, operation: str):
    if not NAME.fullmatch(environment):
        raise ValueError("environment must be a lowercase name containing letters, digits or hyphens")
    if profile not in {"single-node", "distributed"}:
        raise ValueError(f"unsupported deployment profile: {profile}")
    if provider not in PROVIDERS or operation not in OPERATIONS:
        raise ValueError("unsupported provider or operation")
    candidates = []
    directory = root / "topology" / environment / "selfhost"
    for path in sorted(directory.glob("ai-aggregator*.yaml")):
        data = yaml.safe_load(path.read_text())
        if not isinstance(data, dict) or data.get("kind") != "PersonalAIAggregator":
            continue
        metadata = data.get("metadata", {})
        if metadata.get("environment") != environment:
            raise ValueError(f"manifest environment does not match input {environment}: {path}")
        contract = data["spec"]["infrastructure"].get("resource_contract", {})
        if metadata.get("topology", "distributed") == profile and resource_adapter(contract) == provider:
            candidates.append((path, data))
    if len(candidates) != 1:
        raise ValueError(
            f"expected one GitOps declaration for environment={environment} "
            f"profile={profile} provider={provider}; found {len(candidates)} in {directory}"
        )
    path, data = candidates[0]
    selected = provider
    spec = data["spec"]
    infrastructure = spec["infrastructure"]
    enabled = spec.get("enabled", False)
    if not isinstance(enabled, bool):
        raise ValueError(f"spec.enabled must be a YAML boolean: {path}")
    if operation in {"stage", "activate"} and not enabled:
        raise ValueError(f"{operation} requires spec.enabled: true in {path}; no resources will be created")
    if selected == "existing" and operation in {"apply", "provision"}:
        raise ValueError("existing nodes support plan, stage and activate only")
    entries = []
    contract = infrastructure.get("resource_contract", {})
    for raw in contract.get("manifests", []) if selected == "akamai-cloud" else []:
        entry = dict(raw)
        resource_path = Path(entry["path"])
        parts = resource_path.parts
        if (resource_path.is_absolute() or ".." in parts or len(parts) != 5
                or parts[0] != "resources" or parts[2:4] != (environment, "akamai")
                or resource_path.suffix != ".yaml"):
            raise ValueError(f"Akamai resource path must belong to the selected environment: {resource_path}")
        account = entry.get("account", contract.get("account", ""))
        workspace = entry.get("workspace", "")
        if not NAME.fullmatch(account) or not NAME.fullmatch(workspace):
            raise ValueError("Akamai account and workspace must be lowercase names")
        workdir = Path(contract["workdir"]).parent / workspace
        if workdir.is_absolute() or ".." in workdir.parts:
            raise ValueError("Akamai workdir must be relative to iac_modules")
        entry.update(account=account, workdir=str(workdir),
                     state_key=f"terraform/{environment}/{parts[1]}/akamai-cloud/{account}/{workspace}/terraform.tfstate")
        entries.append(entry)
    if selected == "akamai-cloud" and not entries:
        raise ValueError("Akamai provider requires resource_contract.manifests")
    domain = spec.get("entrypoint", {}).get("domain", "")
    return {
        "provider": selected,
        "environment": environment,
        "profile": profile,
        "template_path": str(path),
        "manifest_path": str(root / ".runtime" / environment / "ai-aggregator.yaml"),
        "deployment_enabled": str(enabled).lower(),
        "lifecycle": infrastructure.get("lifecycle", ""),
        "domain_base": domain.partition(".")[2],
        "akamai_matrix": json.dumps({"include": entries}, separators=(",", ":")),
    }


def materialize(outputs):
    """Build a runner-local declaration with event inputs as the selectors."""
    data = yaml.safe_load(Path(outputs["template_path"]).read_text())
    data["metadata"]["environment"] = outputs["environment"]
    infrastructure = data["spec"]["infrastructure"]
    infrastructure["provider"] = outputs["provider"]
    for node in data["spec"].get("nodes", []):
        node["provider"] = outputs["provider"]
    if data["spec"].get("testing_environment"):
        data["spec"]["testing_environment"]["provider"] = outputs["provider"]
    path = Path(outputs["manifest_path"])
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(yaml.safe_dump(data, sort_keys=False))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--gitops-root", type=Path, default=Path("gitops"))
    parser.add_argument("--environment", required=True)
    parser.add_argument("--profile", default="single-node")
    parser.add_argument("--provider", default="gcp")
    parser.add_argument("--operation", default="plan")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    try:
        outputs = resolve(args.gitops_root, args.environment, args.profile, args.provider, args.operation)
    except (ValueError, KeyError) as error:
        parser.exit(1, f"deployment resolution failed: {error}\n")
    materialize(outputs)
    args.output.write_text("".join(f"{key}={value}\n" for key, value in outputs.items()))
    print(f"provider={outputs['provider']} environment={outputs['environment']} manifest={outputs['manifest_path']}")


if __name__ == "__main__":
    main()
