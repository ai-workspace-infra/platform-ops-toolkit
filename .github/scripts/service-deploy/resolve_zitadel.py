"""Resolve one Shared IAM host from GitOps; never guess its project or address."""
import os
from pathlib import Path
import re
import subprocess
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


def resolve_delivery(root):
    root = Path(root)
    config = yaml.safe_load((root / ".doco-cd.zitadel.yaml").read_text())
    if (config.get("name") != "shared-zitadel" or config.get("working_dir") != "compose/zitadel"
            or config.get("compose_files") != ["docker-compose.yml"]
            or config.get("env_files") != [".env.shared"]):
        raise ValueError("IAM Doco-CD must select only the declared ZITADEL stack")
    images = {}
    for line in (root / "compose/zitadel/.env.shared").read_text().splitlines():
        if line and not line.startswith("#"):
            key, value = line.split("=", 1)
            images[key] = value
    result = {}
    for key, image in {"ZITADEL_IMAGE": "zitadel/zitadel", "ZITADEL_LOGIN_IMAGE": "zitadel/zitadel-login",
                       "DOCO_CD_IMAGE": "kimdre/doco-cd"}.items():
        value = images.get(key, "")
        if not re.fullmatch(r"ghcr\.io/" + re.escape(image) + r"@sha256:[0-9a-f]{64}", value):
            raise ValueError(f"GitOps {key} must be digest-pinned")
        result[key.lower()] = value
    return result


if __name__ == "__main__":
    values = resolve("gitops", os.environ["MANIFEST"], os.environ["DEPLOY_ACTION"],
                     os.environ["SERVICE_STAGE"], os.environ["GITHUB_REF"])
    values["gitops_sha"] = subprocess.check_output(["git", "-C", "gitops", "rev-parse", "HEAD"], text=True).strip()
    if os.environ["SERVICE_STAGE"] == "deploy":
        values.update(resolve_delivery("gitops"))
    with open(os.environ["GITHUB_OUTPUT"], "a") as output:
        for key, value in values.items():
            output.write(f"{key}={value}\n")
