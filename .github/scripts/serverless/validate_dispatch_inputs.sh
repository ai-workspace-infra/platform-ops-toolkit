#!/usr/bin/env bash
set -euo pipefail

environment="${VAULT_ENV_PATH:?VAULT_ENV_PATH must be set}"
operation="${OPERATION:-plan}"
target_domains="${TARGET_DOMAINS:-all}"
cloud_provider="${CLOUD_PROVIDER:-vultr-vps}"
tag_ref="${TAG_REF:-}"
deploy_cloudflare="${DEPLOY_CLOUDFLARE:-false}"
deploy_cloud_run="${DEPLOY_CLOUD_RUN:-false}"
serverless_dns_mode="${SERVERLESS_DNS_MODE:-none}"

# The serverless workflow owns only the complete web-saas control plane. `all`
# remains the UI-compatible full-domain selection, but its serverless segment
# resolves to web-saas; other domains belong to the cloud-provider replica path.
case "${target_domains}" in
  all)
    # `all` is the UI-compatible name for the one serverless domain currently
    # wired: the complete web-saas control plane.
    resolved_target_domains="web-saas"
    ;;
  web-saas)
    resolved_target_domains="web-saas"
    ;;
  ai-workspace|infra-platform|agent-proxy|'web-saas + agent-proxy')
    echo "TARGET_DOMAINS=${target_domains} is not deployed by the serverless workflow; serverless is limited to web-saas. Route other domains through the cloud_provider environment replica path" >&2
    exit 2
    ;;
  *)
    echo "TARGET_DOMAINS must be one of: all, ai-workspace, web-saas, infra-platform, agent-proxy, web-saas + agent-proxy" >&2
    exit 2
    ;;
esac

# Other domains are selected through cloud_provider. It is currently wired only
# for Vultr; the other choices intentionally fail before deployment while
# remaining visible as reserved multi-cloud options.
if [[ "${cloud_provider}" != "vultr-vps" ]]; then
  echo "CLOUD_PROVIDER=${cloud_provider} is reserved for a future multi-cloud environment replica path; currently use vultr-vps" >&2
  exit 2
fi

case "${serverless_dns_mode}" in
  none|uat-records|prod-cutover)
    ;;
  *)
    echo "SERVERLESS_DNS_MODE must be one of: none, uat-records, prod-cutover" >&2
    exit 2
    ;;
esac

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

if [[ "${serverless_dns_mode}" != "none" ]] &&
   [[ "${operation}" != "deploy" && "${operation}" != "deploy+migrate" ]]; then
  echo "dns_mode=${serverless_dns_mode} requires operation=deploy or operation=deploy+migrate" >&2
  exit 2
fi

if [[ "${serverless_dns_mode}" != "none" && "${deploy_cloudflare}" != "true" ]]; then
  echo "dns_mode=${serverless_dns_mode} requires deploy_cloudflare=true" >&2
  exit 2
fi

if [[ "${serverless_dns_mode}" == "uat-records" && "${environment}" == "prod" ]]; then
  echo "dns_mode=uat-records is only valid for sit or uat" >&2
  exit 2
fi

if [[ "${serverless_dns_mode}" == "prod-cutover" && "${environment}" != "prod" ]]; then
  echo "dns_mode=prod-cutover requires VAULT_ENV_PATH=prod" >&2
  exit 2
fi

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

echo "Dispatch validated: operation=${operation}, target_domains=${target_domains}, resolved_target_domains=${resolved_target_domains}, cloud_provider=${cloud_provider}, environment=${environment}, tag_ref=${tag_ref}, dns_mode=${serverless_dns_mode}"
