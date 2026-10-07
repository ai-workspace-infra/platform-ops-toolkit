#!/usr/bin/env bash
set -euo pipefail

# GitHub rejects a workflow that declares more than 25 workflow_dispatch inputs.
# The rejection is not local: the file becomes an "Invalid workflow file", and
# every workflow that calls it fails to start with it. data-migration.yaml has
# crossed the line twice (#431, #441) and took selfhost-orchestrator down both
# times, so the cap is asserted here instead of on push to main.

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"

python3 - "${repo_root}/.github/workflows" <<'PY'
from pathlib import Path
import sys

import yaml

MAX_DISPATCH_INPUTS = 25

workflows = sorted(
    p for p in Path(sys.argv[1]).iterdir()
    if p.suffix in (".yml", ".yaml")
)
if not workflows:
    raise SystemExit("no workflow files found -- the guard is looking at the wrong path")

failures = []
for workflow in workflows:
    document = yaml.safe_load(workflow.read_text(encoding="utf-8"))
    if not isinstance(document, dict):
        raise SystemExit(f"{workflow.name} does not parse as a workflow mapping")
    # PyYAML 5/6 parses the YAML 1.1 boolean-like key `on` as True; newer
    # parsers preserve it as a string. Accept both representations so the
    # assertion is about the workflow, not the parser version.
    triggers = document.get("on", document.get(True)) or {}
    dispatch = triggers.get("workflow_dispatch") or {}
    inputs = dispatch.get("inputs") or {}
    if len(inputs) > MAX_DISPATCH_INPUTS:
        failures.append(f"{workflow.name}: {len(inputs)} workflow_dispatch inputs")

if failures:
    raise SystemExit(
        "workflow_dispatch inputs over GitHub's limit of "
        f"{MAX_DISPATCH_INPUTS}:\n  " + "\n  ".join(failures) + "\n"
        "Keep the knob on workflow_call only and read it as "
        "`${{ inputs.x || 'default' }}` in the job."
    )
PY

echo "workflow_dispatch input limit OK"
