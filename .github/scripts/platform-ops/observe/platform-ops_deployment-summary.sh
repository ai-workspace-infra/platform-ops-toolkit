#!/usr/bin/env bash
set -euo pipefail

render_summary() {
  echo "## Platform deployment summary"
  echo
  echo "| Stage | Result |"
  echo "| --- | --- |"
  printf '| Provision | `%s` |\n' "${PROVISION_RESULT:-unknown}"
  printf '| Web SaaS deploy | `%s` |\n' "${WEB_SAAS_DEPLOY_RESULT:-unknown}"
  printf '| DB initialization | `%s` |\n' "${DB_INIT_RESULT:-unknown}"
  printf '| Agent Proxy deploy | `%s` |\n' "${AGENT_PROXY_DEPLOY_RESULT:-unknown}"
  printf '| DNS update | `%s` |\n' "${DNS_UPDATE_RESULT:-unknown}"
  printf '| Web SaaS final status | `%s` |\n' "${WEB_SAAS_STATUS_RESULT:-unknown}"
  printf '| Agent Proxy final status | `%s` |\n' "${AGENT_PROXY_STATUS_RESULT:-unknown}"
  printf '| Data migration | `%s` |\n' "${DATA_MIGRATION_RESULT:-unknown}"
  echo
  printf 'Deployment environment: `%s`\n' "${DEPLOYMENT_ENV:-unknown}"
  printf 'Target domains: `%s`\n' "${TARGET_DOMAINS:-unknown}"
  printf 'Deploy tag: `%s`\n' "${DEPLOY_TAG:-unknown}"
  printf 'Agent Proxy controller: `%s`\n' "${AGENT_CONTROLLER_URL:-not-configured}"
}

if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  render_summary | tee -a "${GITHUB_STEP_SUMMARY}"
else
  render_summary
fi
