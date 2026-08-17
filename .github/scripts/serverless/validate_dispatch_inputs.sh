#!/usr/bin/env bash
set -euo pipefail

environment="${VAULT_ENV_PATH:?VAULT_ENV_PATH must be set}"
operation="${OPERATION:-plan}"
tag_ref="${TAG_REF:-}"
deploy_cloudflare="${DEPLOY_CLOUDFLARE:-false}"
deploy_cloud_run="${DEPLOY_CLOUD_RUN:-false}"

case "${operation}" in
  plan|init-schema|migrate|destroy)
    ;;
  deploy|deploy+migrate)
    if [[ -z "${tag_ref}" ]]; then
      echo "TAG_REF is required for operation=${operation}" >&2
      exit 2
    fi
    ;;
  *)
    echo "OPERATION must be one of: plan, init-schema, deploy, migrate, deploy+migrate, destroy" >&2
    exit 2
    ;;
esac

if [[ "${operation}" == "deploy" || "${operation}" == "deploy+migrate" ]]; then
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
else
  case "${environment}" in
    sit|uat|prod) ;;
    *) echo "VAULT_ENV_PATH must be one of: sit, uat, prod" >&2; exit 2 ;;
  esac
fi

if [[ "${operation}" == "deploy" || "${operation}" == "deploy+migrate" ]] &&
   [[ "${deploy_cloudflare}" != "true" && "${deploy_cloud_run}" != "true" ]]; then
  echo "At least one of deploy_cloudflare or deploy_cloud_run must be enabled for operation=${operation}" >&2
  exit 2
fi

echo "Dispatch validated: operation=${operation}, environment=${environment}, tag_ref=${tag_ref}"
