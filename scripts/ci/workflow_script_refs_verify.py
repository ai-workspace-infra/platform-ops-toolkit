#!/usr/bin/env python3
"""Assert that every script a workflow step calls is actually there when it runs.

Pipeline steps live in three repositories: orchestration in this one,
Terraform-phase steps in iac_modules/scripts/pipeline, Ansible-phase steps in
playbooks/scripts/pipeline. A dangling path does not fail review or lint -- it
fails as `No such file or directory` in the middle of a provision run. These
checks turn that into a pull-request failure:

  R1  a `.github/scripts/...` or `.github/actions/...` path used by a workflow
      or composite action does not exist in this repository
  R2  a `uses: ./.github/actions/<name>` has no action.yml, or a job calls a
      reusable workflow file that does not exist
  R3  a step calls <checkout>/scripts/pipeline/... of iac_modules or playbooks
      but no earlier step of the same job checks that repository out at that
      path (or the checkout is conditional and the step is not)
  R4  that script does not exist in the sibling repository, or is called bare
      without the exec bit (only checked when the sibling checkout is given)

Usage:
  workflow_script_refs_verify.py [--iac-root DIR] [--playbooks-root DIR]

Without the --*-root options R4 is skipped for that repository; R1-R3 always run.
Exit 0 = all pass. Non-zero = at least one violation, listed on stderr.
"""

import argparse
import os
import re
import sys
from pathlib import Path

try:
    import yaml
except ImportError:
    sys.exit("PyYAML is required: pip install pyyaml")

REPO_ROOT = Path(__file__).resolve().parents[2]
WORKFLOW_DIR = REPO_ROOT / ".github" / "workflows"
ACTION_DIR = REPO_ROOT / ".github" / "actions"

SIBLINGS = {
    "iac_modules": "ai-workspace-infra/iac_modules",
    "playbooks": "ai-workspace-infra/playbooks",
}

EXPR = re.compile(r"\$\{\{.*?\}\}")
LOCAL_REF = re.compile(r"\.github/(?:scripts|actions)/[\w./-]+\.(?:sh|py|rb|js|sql|json)\b")
WORKSPACE = re.compile(r"\$\{\{\s*github\.workspace\s*\}\}|\$\{?GITHUB_WORKSPACE\}?")
SIBLING_REF = re.compile(
    r"(?<![\w.-])((?:[\w-]+/)*?)(iac_modules|playbooks)/(scripts/pipeline/[\w./-]+\.(?:sh|py))")
INTERPRETERS = ("bash", "sh", "python", "python3", "ruby", "source", ".")

violations = []
checked = {"local": 0, "sibling": 0}


def fail(where, message):
    violations.append(f"{where}: {message}")


def load(path):
    with open(path, encoding="utf-8") as handle:
        return yaml.safe_load(handle)


def is_bare_call(run, start):
    """True when the path at run[start:] is in command position (needs +x)."""
    line_start = run.rfind("\n", 0, start) + 1
    before = EXPR.sub("", run[line_start:start])
    before = re.sub(r"\$\{?GITHUB_WORKSPACE\}?", "", before).strip().strip("\"'/.")
    words = before.split()
    if not words:
        return True
    return words[-1] not in INTERPRETERS and not any(w in INTERPRETERS for w in words)


def check_local_refs(where, run, root_repo, roots):
    """root_repo is the repository checked out at the workspace root: None for
    this repository, otherwise the sibling whose tree `.github/...` resolves in."""
    base, owner = REPO_ROOT, "this repository"
    if root_repo is not None:
        name = root_repo.rsplit("/", 1)[-1]
        if name not in roots:
            return
        base, owner = roots[name], root_repo
    text = WORKSPACE.sub("", run)
    for match in LOCAL_REF.finditer(text):
        ref = match.group(0)
        # Only a path anchored at the workspace root is ours: `gitops/.github/...`
        # or `$dir/.github/...` belongs to whatever is checked out or built there.
        lead = re.split(r"[\s\"'=(]", text[:match.start()])[-1]
        if lead.strip("./") != "":
            continue
        checked["local"] += 1
        if not (base / ref).is_file():
            fail(where, f"R1 references {ref}, which is not in {owner}")


def check_uses(where, uses, reusable=False):
    if not (isinstance(uses, str) and uses.startswith("./")):
        return
    target = REPO_ROOT / uses[2:]
    if reusable:
        if not target.is_file():
            fail(where, f"R2 calls reusable workflow {uses}, which does not exist")
    elif not ((target / "action.yml").is_file() or (target / "action.yaml").is_file()):
        fail(where, f"R2 uses {uses}, which has no action.yml")


def check_sibling_refs(where, step, run, checkouts, roots):
    for match in SIBLING_REF.finditer(run):
        prefix, repo, rel = match.groups()
        checked["sibling"] += 1
        checkout_path = f"{prefix}{repo}"
        checkout = checkouts.get((SIBLINGS[repo], checkout_path))
        if checkout is None:
            fail(where, f"R3 calls {checkout_path}/{rel} but no earlier step checks out "
                        f"{SIBLINGS[repo]} at path {checkout_path}")
        elif checkout.get("if") and not step.get("if"):
            fail(where, f"R3 calls {checkout_path}/{rel} unconditionally, but the "
                        f"{SIBLINGS[repo]} checkout is conditional")
        root = roots.get(repo)
        if root is None:
            continue
        script = root / rel
        if not script.is_file():
            fail(where, f"R4 {SIBLINGS[repo]} has no {rel}")
        elif is_bare_call(run, match.start()) and not os.access(script, os.X_OK):
            fail(where, f"R4 {SIBLINGS[repo]}:{rel} is called bare but is not executable")


def walk_steps(where, steps, roots):
    checkouts = {}
    root_repo = None
    for index, step in enumerate(steps or []):
        if not isinstance(step, dict):
            continue
        label = f"{where} step {index + 1} ({step.get('name') or step.get('uses') or 'run'})"
        uses = step.get("uses")
        check_uses(label, uses)
        if isinstance(uses, str) and uses.startswith("actions/checkout@"):
            options = step.get("with") or {}
            repository = options.get("repository")
            path = str(options.get("path", ""))
            if repository in SIBLINGS.values():
                checkouts[(repository, path)] = step
            if path in ("", "."):
                root_repo = repository if repository and "${{" not in repository else None
        run = step.get("run")
        if isinstance(run, str):
            check_local_refs(label, run, root_repo, roots)
            check_sibling_refs(label, step, run, checkouts, roots)


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--iac-root", type=Path)
    parser.add_argument("--playbooks-root", type=Path)
    args = parser.parse_args()
    roots = {}
    for repo, root in (("iac_modules", args.iac_root), ("playbooks", args.playbooks_root)):
        if root is not None:
            if not (root / "scripts" / "pipeline").is_dir():
                sys.exit(f"{root} is not a checkout of {SIBLINGS[repo]} with scripts/pipeline")
            roots[repo] = root

    workflows = sorted(list(WORKFLOW_DIR.glob("*.yml")) + list(WORKFLOW_DIR.glob("*.yaml")))
    for path in workflows:
        document = load(path) or {}
        for job_id, job in (document.get("jobs") or {}).items():
            if not isinstance(job, dict):
                continue
            check_uses(f"{path.name} job {job_id}", job.get("uses"), reusable=True)
            walk_steps(f"{path.name} job {job_id}", job.get("steps"), roots)

    actions = sorted(list(ACTION_DIR.glob("*/action.yml")) + list(ACTION_DIR.glob("*/action.yaml")))
    for path in actions:
        document = load(path) or {}
        name = f"actions/{path.parent.name}"
        steps = (document.get("runs") or {}).get("steps")
        walk_steps(name, steps, roots)
        for step in steps or []:
            run = step.get("run") if isinstance(step, dict) else None
            if not isinstance(run, str):
                continue
            # Composite actions address their own files through github.action_path.
            for match in re.finditer(r"github\.action_path\s*\}\}/([\w./-]+)", run):
                if not (path.parent / match.group(1)).is_file():
                    fail(name, f"R1 references {match.group(1)}, which is not in {path.parent.name}/")

    if violations:
        print(f"{len(violations)} script reference violation(s):", file=sys.stderr)
        for line in violations:
            print(f"  {line}", file=sys.stderr)
        return 1
    rules = "R1-R4" if len(roots) == len(SIBLINGS) else "R1-R3"
    print(f"workflow script references OK ({len(workflows)} workflows, {len(actions)} actions, "
          f"{checked['local']} local and {checked['sibling']} sibling-repo calls, {rules})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
