#!/usr/bin/env python3
"""Verify cross-repository ownership contracts without contacting cloud APIs."""

from __future__ import annotations

import argparse
import hashlib
import subprocess
import sys
from pathlib import Path


def git_files(root: Path) -> list[Path]:
    result = subprocess.run(
        ["git", "-C", str(root), "ls-files"],
        check=True,
        text=True,
        capture_output=True,
    )
    return [root / line for line in result.stdout.splitlines() if line]


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def fail(message: str) -> None:
    raise SystemExit(f"::error::{message}")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--toolkit-root", type=Path, default=Path.cwd())
    parser.add_argument("--iac-root", type=Path, required=True)
    parser.add_argument("--playbooks-root", type=Path, required=True)
    parser.add_argument("--gitops-root", type=Path, required=True)
    args = parser.parse_args()

    toolkit = args.toolkit_root.resolve()
    iac = args.iac_root.resolve()
    playbooks = args.playbooks_root.resolve()
    gitops = args.gitops_root.resolve()

    require_env = [
        toolkit / ".github/scripts/lib/require-env.sh",
        iac / "scripts/pipeline/lib/require-env.sh",
        playbooks / "scripts/pipeline/lib/require-env.sh",
    ]
    missing = [str(path) for path in require_env if not path.is_file()]
    if missing:
        fail("missing require-env.sh: " + ", ".join(missing))
    hashes = {sha256(path) for path in require_env}
    if len(hashes) != 1:
        fail("the three require-env.sh copies are not byte-identical")

    toolkit_scripts = toolkit / ".github/scripts"
    forbidden_pipeline_paths = [
        path
        for path in toolkit_scripts.rglob("*")
        if path.is_file() and "pipeline" in path.relative_to(toolkit_scripts).parts
    ]
    if forbidden_pipeline_paths:
        fail(
            "toolkit must not own scripts/pipeline semantics: "
            + ", ".join(str(path.relative_to(toolkit)) for path in forbidden_pipeline_paths)
        )

    declaration_roots = ["resources", "topology", "services", "environments"]
    forbidden_suffixes = {".sh", ".bash", ".py", ".rb", ".pl", ".tf", ".tf.json"}
    forbidden = []
    for relative in git_files(gitops):
        if not any(relative.is_relative_to(gitops / root) for root in declaration_roots):
            continue
        if relative.suffix in forbidden_suffixes:
            forbidden.append(str(relative.relative_to(gitops)))
    if forbidden:
        fail("GitOps declaration directories contain executable/IaC files: " + ", ".join(forbidden))

    print("repository conventions OK")
    print(f"require-env sha256={next(iter(hashes))}")
    print("toolkit owns orchestration; iac_modules/playbooks own pipeline phases; gitops is data-only")
    return 0


if __name__ == "__main__":
    sys.exit(main())
