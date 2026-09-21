#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Contract test for XConnect Zero Cloud Lab AI-Aggregator Matrix Jobs
# =============================================================================

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
workflow="${repo_root}/.github/workflows/xconnect-zero-cloud.yaml"
enroll_script="${repo_root}/.github/scripts/xconnect-lab/enroll-node.sh"

test -f "${workflow}" || { echo "::error::Missing ${workflow}" >&2; exit 1; }
test -f "${enroll_script}" || { echo "::error::Missing ${enroll_script}" >&2; exit 1; }
bash -n "${enroll_script}"

# Validate job definitions and matrix structure
grep -Fq 'enroll_node_matrix:' "${workflow}" || {
  echo "::error::Workflow must define dedicated jobs matrix: enroll_node_matrix" >&2
  exit 1
}

grep -Fq 'reconcile_mesh:' "${workflow}" || {
  echo "::error::Workflow must define converged reconciliation job: reconcile_mesh" >&2
  exit 1
}

# Validate that the matrix is resolved from GitOps rather than hard-coded.
grep -Fq 'resolve_ai_aggregator_matrix:' "${workflow}" || {
  echo "::error::Workflow must resolve the AI Aggregator matrix from GitOps" >&2
  exit 1
}
grep -Fq 'fromJSON(needs.resolve_ai_aggregator_matrix.outputs.matrix)' "${workflow}" || {
  echo "::error::Enrollment matrix must consume the GitOps-derived job output" >&2
  exit 1
}
if grep -Eq 'id: cpa-[a-z0-9-]+' "${workflow}"; then
  echo "::error::Workflow must not hard-code CPA node IDs" >&2
  exit 1
fi

# Validate the workflow parser sees a dynamic matrix expression.
python3 - "${workflow}" <<'PY'
import sys
import yaml

with open(sys.argv[1], "r", encoding="utf-8") as f:
    doc = yaml.safe_load(f)

jobs = doc.get("jobs", {})
matrix_job = jobs.get("enroll_node_matrix")
if not matrix_job:
    raise SystemExit("enroll_node_matrix job missing in parsed YAML")

strategy = matrix_job.get("strategy", {})
matrix = strategy.get("matrix", {})
expression = matrix.get("node")
if not isinstance(expression, str) or "resolve_ai_aggregator_matrix.outputs.matrix" not in expression:
    raise SystemExit("strategy.matrix.node must consume the GitOps-derived output")

PY

echo "xconnect_ai_aggregator_matrix_contract_test: PASS"
