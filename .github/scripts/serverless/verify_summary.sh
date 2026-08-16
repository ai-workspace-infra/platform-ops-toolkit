#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
ORCHESTRATOR="${REPO_ROOT}/scripts/serverless_uat/deploy_orchestrator.py"

DEPLOY_CLOUDFLARE=false \
DEPLOY_CLOUD_RUN=false \
VERIFY_SUPABASE=true \
python3 "${ORCHESTRATOR}"

{
  echo "## Serverless verification summary"
  echo
  echo "| Stage | Result |"
  echo "| --- | --- |"
  echo "| Supabase | ${SUPABASE_RESULT:-unknown} |"
  echo "| Cloud Run | ${CLOUD_RUN_RESULT:-unknown} |"
  echo "| Cloudflare Pages | ${CLOUDFLARE_RESULT:-unknown} |"
  echo "| Edge worker | ${EDGE_WORKER_RESULT:-unknown} |"
  echo "| Edge gateway | ${EDGE_GATEWAY_RESULT:-unknown} |"
  echo "| Verify | success |"
} >> "${GITHUB_STEP_SUMMARY:-/dev/null}"

for result in "${SUPABASE_RESULT:-}" "${CLOUD_RUN_RESULT:-}" "${CLOUDFLARE_RESULT:-}" "${EDGE_WORKER_RESULT:-}" "${EDGE_GATEWAY_RESULT:-}"; do
  case "${result}" in
    failure|cancelled)
      exit 1
      ;;
  esac
done
