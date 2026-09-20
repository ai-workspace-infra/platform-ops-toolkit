#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
workflow="${repo_root}/.github/workflows/xconnect-zero-cloud.yaml"

python3 - "${workflow}" <<'PY'
from pathlib import Path
import sys
import yaml

document = yaml.safe_load(Path(sys.argv[1]).read_text(encoding="utf-8"))
jobs = document["jobs"]
preflight = jobs.get("preflight")
apply = jobs.get("apply")
cleanup = jobs.get("cleanup")

if not preflight:
    raise SystemExit("XConnect cloud lab must have a preflight job")
matrix = preflight.get("strategy", {}).get("matrix", {})
if matrix.get("suite") != ["contracts", "runtime"]:
    raise SystemExit("preflight must retain contracts/runtime job matrix")
if apply.get("needs") != "preflight":
    raise SystemExit("apply must be gated by the complete preflight matrix")
if "inputs.mode != 'cleanup'" not in apply.get("if", ""):
    raise SystemExit("apply must not run for explicit cleanup")
if cleanup.get("needs") != "preflight":
    raise SystemExit("cleanup must be gated by the complete preflight matrix")
if "inputs.mode == 'cleanup'" not in cleanup.get("if", ""):
    raise SystemExit("cleanup must require explicit cleanup mode")

for job_name in ("apply", "cleanup"):
    if not any(step.get("run", "").endswith("run.sh prepare") for step in jobs[job_name].get("steps", [])):
        raise SystemExit(f"{job_name} must initialize its isolated Terraform state")

print("xconnect_cloud_lab_jobs_matrix_contract_test: PASS")
PY

if grep -Fq 'strategy:' "${workflow}" && grep -Fq 'matrix:' "${workflow}"; then
  :
else
  echo 'XConnect cloud lab matrix strategy is missing' >&2
  exit 1
fi
