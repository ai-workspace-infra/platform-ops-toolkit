"""Resolve one Shared IAM host from GitOps; never guess its project or address."""
import os
from pathlib import Path
import re
import yaml


def resolve(root, manifest, action, stage, ref):
    if ref != "refs/heads/main":
        raise ValueError("Shared IAM delivery must run from main")
    if action not in {"none", "plan", "apply"} or stage not in {"none", "deploy", "verify"}:
        raise ValueError("unsupported operation")
    if (action == "none" and stage == "none") or (action == "plan" and stage != "none"):
        raise ValueError("choose plan alone, apply with an optional stage, or none with a stage")
    root = Path(root).resolve()
    path = (root / manifest).resolve()
    if not path.is_relative_to(root) or not manifest.startswith("resources/"):
        raise ValueError("manifest must be inside GitOps resources")
    doc = yaml.safe_load(path.read_text())
    metadata, spec = doc["metadata"], doc["spec"]
    if metadata["environment"] != "shared" or metadata["provider"] != "gcp":
        raise ValueError("a Shared GCP declaration is required")
    if metadata["name"] != "open-platform-shared-iam":
        raise ValueError("the independent Shared IAM namespace is required")
    nodes = spec["resources"]["vault_nodes"]
    if len(nodes) != 1 or nodes[0].get("public_ip") is not True or spec.get("enable_oslogin") is not True:
        raise ValueError("exactly one public OS Login IAM node is required")
    node = nodes[0]
    domains = node["service_domains"]
    if len(domains) != 1:
        raise ValueError("exactly one IAM service domain is required")
    values = dict(account=spec["gcp_account_id"], project=spec["project_id"],
                  network=spec["network_name"], node=node["name"], zone=node["zone"], domain=domains[0])
    if not all(isinstance(v, str) and re.fullmatch(r"[a-z0-9][a-z0-9.-]*", v) for v in values.values()):
        raise ValueError("invalid declaration identity")
    return values


if __name__ == "__main__":
    values = resolve("gitops", os.environ["MANIFEST"], os.environ["DEPLOY_ACTION"],
                     os.environ["SERVICE_STAGE"], os.environ["GITHUB_REF"])
    with open(os.environ["GITHUB_OUTPUT"], "a") as output:
        for key, value in values.items():
            output.write(f"{key}={value}\n")
