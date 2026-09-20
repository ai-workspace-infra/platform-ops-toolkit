#!/usr/bin/env python3
"""Static, dry-run-only coverage check for the multi-cloud IAC contract.

The check deliberately does not invoke Terraform, a cloud API, Vault, or a
GitHub token.  It verifies the parts that can be checked safely before a
provider-specific plan: registry routing, module layout, GitOps declarations,
and the canonical state key.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
from pathlib import Path
from typing import Any, Iterable


STATE_PROJECT = "platform-ops-toolkit"


def read_json(path: Path) -> dict[str, Any]:
    with path.open(encoding="utf-8") as handle:
        value = json.load(handle)
    if not isinstance(value, dict):
        raise ValueError(f"expected a JSON object: {path}")
    return value


def unique(values: Iterable[str]) -> list[str]:
    return sorted({value for value in values if value})


def scalar_from_text(text: str, key: str) -> list[str]:
    pattern = re.compile(rf"^\s*{re.escape(key)}:\s*['\"]?([^'\"#\n]+)")
    return [match.group(1).strip() for match in pattern.finditer(text)]


def quoted_or_scalar(value: str) -> str:
    value = value.strip().split(" #", 1)[0].strip()
    if len(value) >= 2 and value[0] == value[-1] and value[0] in "'\"":
        return value[1:-1]
    return value


def manifest_values(path: Path) -> dict[str, list[str]]:
    """Extract the coverage fields without requiring PyYAML on the runner.

    GitOps manifests are intentionally declarative and keep these fields as
    plain scalars/lists.  The optional PyYAML path improves accuracy locally;
    the line-oriented fallback keeps the workflow dependency-free.
    """

    text = path.read_text(encoding="utf-8")
    result: dict[str, list[str]] = {
        "regions": [],
        "resources": [],
        "services": [],
    }

    try:
        import yaml  # type: ignore

        document = yaml.safe_load(text) or {}

        def walk(value: Any, parent_key: str = "") -> None:
            if isinstance(value, dict):
                for key, child in value.items():
                    key_text = str(key)
                    if key_text in {"region", "regions"}:
                        if isinstance(child, list):
                            result["regions"].extend(str(item) for item in child)
                        elif child is not None:
                            result["regions"].append(str(child))
                    if key_text in {"name", "resource", "resource_name", "instance_name", "type", "image"}:
                        if child is not None and not isinstance(child, (dict, list)):
                            result["resources"].append(str(child))
                    if key_text in {"service", "service_name", "workspace", "domain", "service_domains"}:
                        if isinstance(child, list):
                            result["services"].extend(str(item) for item in child)
                        elif child is not None and not isinstance(child, dict):
                            result["services"].append(str(child))
                    walk(child, key_text)
            elif isinstance(value, list):
                for child in value:
                    walk(child, parent_key)

        walk(document)
    except Exception:
        # Some GitOps files are renderer templates and therefore are not valid
        # standalone YAML until their Jinja variables are resolved.  Coverage
        # inspection must still work for those declarations.
        result = {"regions": [], "resources": [], "services": []}
        result["regions"].extend(scalar_from_text(text, "region"))
        for key in ("name", "resource", "resource_name", "instance_name", "type", "image"):
            result["resources"].extend(scalar_from_text(text, key))
        for key in ("service", "service_name", "workspace", "domain"):
            result["services"].extend(scalar_from_text(text, key))
        in_service_domains = False
        for line in text.splitlines():
            if re.match(r"^\s*service_domains:\s*$", line):
                in_service_domains = True
                continue
            if in_service_domains and re.match(r"^\s*-\s+", line):
                result["services"].append(quoted_or_scalar(line.split("-", 1)[1]))
                continue
            if in_service_domains and line and not re.match(r"^\s+", line):
                in_service_domains = False

    # The manifest filename is itself the service declaration when no explicit
    # service/workspace field is present (for example web-saas.yaml).
    result["services"].append(path.stem)
    return {key: unique(values) for key, values in result.items()}


def module_inventory(module_root: Path) -> dict[str, list[str]]:
    if not module_root.is_dir():
        return {"module_dirs": [], "terraform_files": []}

    module_dirs: list[str] = []
    for container in ("modules", "component", "instance", "envs"):
        directory = module_root / container
        if directory.is_dir():
            module_dirs.extend(
                f"{container}/{child.name}"
                for child in directory.iterdir()
                if child.is_dir() and not child.name.startswith(".")
            )
    terraform_files = [
        str(path.relative_to(module_root))
        for path in module_root.rglob("*.tf")
        if ".terraform" not in path.parts
    ]
    return {
        "module_dirs": unique(module_dirs),
        "terraform_files": unique(terraform_files),
    }


def check_provider(
    provider: str,
    registry: dict[str, Any],
    defaults: dict[str, Any],
    iac_root: Path,
    gitops_root: Path,
    environment: str,
    project: str,
    account_override: str,
) -> dict[str, Any]:
    issues: list[str] = []
    metadata = registry.get(provider)
    if not isinstance(metadata, dict):
        return {
            "provider": provider,
            "status": "FAIL",
            "issues": ["provider is not present in config/iac_provider_registry.json"],
        }

    provisioner = metadata.get("provisioner", "")
    tree = metadata.get("terraform_tree")
    gitops_provider = metadata.get("gitops_provider", "")
    account = account_override or defaults.get(environment, {}).get("account", "")
    state_key = f"terraform/{environment}/{STATE_PROJECT}/{provider}/{account}/self-check/terraform.tfstate"

    if provisioner != "terraform":
        issues.append(f"provisioner={provisioner!r} is not eligible for Terraform self-check")
    if not tree:
        issues.append("registry has no terraform_tree")

    module_root = iac_root / "terraform-hcl-standard" / str(tree)
    modules = module_inventory(module_root)
    if not module_root.is_dir():
        issues.append(f"Terraform module tree is missing: {module_root}")
    elif not modules["terraform_files"]:
        issues.append("Terraform module tree contains no .tf files")

    manifest_dir = gitops_root / "resources" / project / environment / str(gitops_provider)
    manifest_files = sorted(manifest_dir.glob("*.yaml")) if manifest_dir.is_dir() else []
    coverage = {"regions": [], "resources": [], "services": []}
    for manifest in manifest_files:
        values = manifest_values(manifest)
        for key in coverage:
            coverage[key].extend(values[key])
    coverage = {key: unique(values) for key, values in coverage.items()}

    if not manifest_files:
        issues.append(f"no GitOps declarations under {manifest_dir}")

    status = "FAIL" if any(
        "missing" in issue or "not present" in issue or "not eligible" in issue or "no terraform_tree" in issue
        for issue in issues
    ) else ("WARN" if issues else "PASS")

    return {
        "provider": provider,
        "status": status,
        "provisioner": provisioner,
        "terraform_tree": tree or "",
        "gitops_provider": gitops_provider,
        "credential_mode": metadata.get("credential_mode", ""),
        "account": account,
        "state_key": state_key,
        "module_root": str(module_root),
        "module_dirs": modules["module_dirs"],
        "terraform_file_count": len(modules["terraform_files"]),
        "manifest_dir": str(manifest_dir),
        "manifest_files": [str(path.relative_to(gitops_root)) for path in manifest_files],
        "manifest_count": len(manifest_files),
        "regions": coverage["regions"],
        "resources": coverage["resources"],
        "services": coverage["services"],
        "issues": issues,
        "dry_run": True,
    }


def markdown_row(item: dict[str, Any]) -> str:
    def cell(key: str) -> str:
        values = item.get(key, [])
        if isinstance(values, list):
            return ", ".join(str(value) for value in values) or "—"
        return str(values or "—")

    return (
        f"| `{item.get('provider', '')}` | {item.get('status', '')} | "
        f"`{item.get('terraform_tree', '') or '—'}` | `{item.get('account', '') or '—'}` | "
        f"{cell('regions')} | {cell('resources')} | {cell('services')} |"
    )


def render_summary(items: list[dict[str, Any]], environment: str, project: str) -> str:
    lines = [
        "## IAC self-check matrix (dry-run only)",
        "",
        f"Environment: `{environment}`  ",
        f"Project: `{project}`  ",
        "Execution mode: `dry-run` — no Vault login, cloud API call, Terraform apply, or destroy.",
        "",
        "| Provider | Result | Terraform module | Account | Regions | Resources | Services |",
        "| --- | --- | --- | --- | --- | --- | --- |",
    ]
    lines.extend(markdown_row(item) for item in items)
    lines.extend(["", "### State and module coverage", ""])
    for item in items:
        lines.append(
            f"- `{item.get('provider')}`: state `{item.get('state_key', '—')}`, "
            f"GitOps manifests `{item.get('manifest_count', 0)}`, Terraform files `{item.get('terraform_file_count', 0)}`, "
            f"modules `{', '.join(item.get('module_dirs', [])) or '—'}`."
        )
        for issue in item.get("issues", []):
            lines.append(f"  - {item.get('status')}: {issue}")
    return "\n".join(lines) + "\n"


def aggregate(report_dir: Path) -> list[dict[str, Any]]:
    reports: list[dict[str, Any]] = []
    for path in sorted(report_dir.rglob("*.json")):
        try:
            value = read_json(path)
        except (OSError, ValueError, json.JSONDecodeError):
            continue
        if value.get("provider"):
            reports.append(value)
    return sorted(reports, key=lambda item: str(item.get("provider")))


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--registry", type=Path)
    parser.add_argument("--defaults", type=Path)
    parser.add_argument("--iac-root", type=Path)
    parser.add_argument("--gitops-root", type=Path)
    parser.add_argument("--environment", default="uat")
    parser.add_argument("--project", default="svc.plus")
    parser.add_argument("--provider")
    parser.add_argument("--account", default="")
    parser.add_argument("--output-json", type=Path)
    parser.add_argument("--summary-file", type=Path)
    parser.add_argument("--aggregate-dir", type=Path)
    parser.add_argument("--dry-run", action="store_true", default=True)
    args = parser.parse_args()

    if args.aggregate_dir:
        items = aggregate(args.aggregate_dir)
        summary = render_summary(items, args.environment, args.project)
        if args.summary_file:
            args.summary_file.write_text(summary, encoding="utf-8")
        else:
            print(summary, end="")
        return 1 if any(item.get("status") == "FAIL" for item in items) else 0

    required = (args.registry, args.defaults, args.iac_root, args.gitops_root, args.provider)
    if any(value is None for value in required):
        parser.error("provider checks require --registry, --defaults, --iac-root, --gitops-root, and --provider")

    registry = read_json(args.registry)
    defaults = read_json(args.defaults)
    item = check_provider(
        args.provider,
        registry,
        defaults,
        args.iac_root,
        args.gitops_root,
        args.environment,
        args.project,
        args.account,
    )
    if args.output_json:
        args.output_json.write_text(json.dumps(item, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    summary = render_summary([item], args.environment, args.project)
    if args.summary_file:
        args.summary_file.write_text(summary, encoding="utf-8")
    else:
        print(summary, end="")
    return 1 if item["status"] == "FAIL" else 0


if __name__ == "__main__":
    sys.exit(main())
