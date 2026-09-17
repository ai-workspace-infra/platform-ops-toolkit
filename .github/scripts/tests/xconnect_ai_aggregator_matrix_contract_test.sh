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

# Validate all ai-aggregator nodes are present in the matrix
required_nodes=(gateway-01 cpa-codex-01 cpa-claude-01 cpa-codex-02 cpa-grok-01)
for node in "${required_nodes[@]}"; do
  grep -Fq "id: ${node}" "${workflow}" || {
    echo "::error::Matrix is missing required AI Aggregator node: ${node}" >&2
    exit 1
  }
done

# Validate Python parsing of workflow matrix
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
nodes = matrix.get("node", [])
if not nodes:
    raise SystemExit("strategy.matrix.node list is empty or missing")

node_ids = {n.get("id") for n in nodes if isinstance(n, dict)}
expected = {"gateway-01", "cpa-codex-01", "cpa-claude-01", "cpa-codex-02", "cpa-grok-01"}
missing = expected - node_ids
if missing:
    raise SystemExit(f"Missing expected nodes in matrix: {missing}")

PY

echo "xconnect_ai_aggregator_matrix_contract_test: PASS"
