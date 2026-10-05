#!/usr/bin/env bash
set -euo pipefail

# Fixed control-plane entrypoint for a future reviewed Playbooks adapter.
# The registry remains empty until Playbooks can return real, bound receipts.
# This file must never accept a workflow-provided command, SQL, DSN, secret,
# repository, or moving ref.

phase="${UPGRADE_PHASE:-}"
case "$phase" in
  preflight|backup|migration|promotion|verification) ;;
  rollback|repromotion|final_verification)
    echo "::error::rollback rehearsal adapter is not registered" >&2
    exit 1
    ;;
  *)
    echo "::error::unsupported environment-upgrade phase" >&2
    exit 1
    ;;
esac

if [[ "${DEPLOY_ENV:-}" != "uat" ]]; then
  echo "::error::live delegate is UAT-only until an independently approved PROD adapter exists" >&2
  exit 1
fi

[[ "${UPGRADE_PLAYBOOKS_REPOSITORY:-}" == "ai-workspace-infra/playbooks" ]] || {
  echo "::error::delegate requires the approved Playbooks repository" >&2
  exit 1
}
[[ "${UPGRADE_PLAYBOOKS_REF:-}" =~ ^[0-9a-f]{40}$ ]] || {
  echo "::error::delegate requires an immutable Playbooks commit" >&2
  exit 1
}
[[ "${UPGRADE_PLAYBOOKS_WORKFLOW:-}" == ".github/workflows/selfhost-data-lifecycle.yml" ]] || {
  echo "::error::delegate requires the fixed selfhost data lifecycle workflow" >&2
  exit 1
}
[[ "${UPGRADE_OPERATION:-}" == "$phase" ]] || {
  echo "::error::delegate operation does not match the requested phase" >&2
  exit 1
}

# A real adapter must be reviewed with the Playbooks owner and produce a
# receipt at UPGRADE_RECEIPT_FILE. Until then, fail before any dispatch or
# credential lookup; no synthetic receipt is written.
echo "::error::reviewed Playbooks execution adapter is not registered" >&2
exit 1
