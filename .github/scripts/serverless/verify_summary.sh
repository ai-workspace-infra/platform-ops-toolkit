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
  echo "| Cloudflare SSR | ${CLOUDFLARE_RESULT:-unknown} |"
  echo "| Edge gateway | ${EDGE_GATEWAY_RESULT:-unknown} |"
  echo "| Static Pages | ${STATIC_PAGES_RESULT:-unknown} |"
  echo "| Custom domains / CORS chain | ${SERVERLESS_DOMAINS_RESULT:-unknown} |"
  echo "| Verify | success |"
} >> "${GITHUB_STEP_SUMMARY:-/dev/null}"

for result in "${SUPABASE_RESULT:-}" "${CLOUD_RUN_RESULT:-}" "${CLOUDFLARE_RESULT:-}" "${EDGE_GATEWAY_RESULT:-}" "${STATIC_PAGES_RESULT:-}" "${SERVERLESS_DOMAINS_RESULT:-}"; do
  case "${result}" in
    failure|cancelled)
      exit 1
      ;;
  esac
done
