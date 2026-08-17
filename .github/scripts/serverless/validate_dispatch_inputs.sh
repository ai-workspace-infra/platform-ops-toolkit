#!/usr/bin/env bash
set -euo pipefail

environment="${VAULT_ENV_PATH:?VAULT_ENV_PATH must be set}"
tag_ref="${TAG_REF:?TAG_REF must be set}"
deploy_cloudflare="${DEPLOY_CLOUDFLARE:-false}"
deploy_cloud_run="${DEPLOY_CLOUD_RUN:-false}"
verify_supabase="${VERIFY_SUPABASE:-false}"

case "${environment}" in
  sit|uat)
    if [[ ! "${tag_ref}" =~ ^(uat-)?daily-build-[0-9]{4}\.[0-9]{2}\.[0-9]{2}(-r[1-9][0-9]*)?$ ]]; then
      echo "TAG_REF for ${environment} must be an immutable daily-build snapshot (for example daily-build-2026.08.17-r1)" >&2
      exit 2
    fi
    ;;
  prod)
    if [[ ! "${tag_ref}" =~ ^v([0-9]+\.[0-9]+\.[0-9]+|[0-9]{4}\.[0-9]{2}\.[0-9]{2})$ ]]; then
      echo "TAG_REF for prod must be a formal release tag (for example v2026.08.17 or v1.2.3)" >&2
      exit 2
    fi
    ;;
  *)
    echo "VAULT_ENV_PATH must be one of: sit, uat, prod" >&2
    exit 2
    ;;
esac

if [[ "${deploy_cloudflare}" != "true" && "${deploy_cloud_run}" != "true" && "${verify_supabase}" != "true" ]]; then
  echo "At least one of deploy_cloudflare, deploy_cloud_run, or verify_supabase must be enabled" >&2
  exit 2
fi

echo "Dispatch validated: environment=${environment}, tag_ref=${tag_ref}"
