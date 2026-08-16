#!/usr/bin/env bash
set -euo pipefail

# -----------------------------------------------------------------------------
# UAT Cloud Run 批量部署脚本
# 默认副本数 min-instances=0, max-instances=2
# -----------------------------------------------------------------------------

GCP_PROJECT="${GCP_PROJECT_ID:-ai-workspace-uat-project}"
GCP_REGION="${GCP_REGION:-asia-east1}"
GCP_ARTIFACT_REGISTRY_REGION="${GCP_ARTIFACT_REGISTRY_REGION:-${GCP_REGION}}"
IMAGE_TAG="${IMAGE_TAG:-latest}"
DEPLOY_ENV="${DEPLOY_ENV:-uat}"

if [[ -z "${SUPABASE_CONNECT_URI:-}" ]]; then
  echo "SUPABASE_CONNECT_URI is required for Cloud Run deployment" >&2
  exit 1
fi
if [[ -z "${INTERNAL_SERVICE_TOKEN:-}" ]]; then
  echo "INTERNAL_SERVICE_TOKEN is required for Cloud Run deployment" >&2
  exit 1
fi

SERVICES=("accounts" "billing-service" "content-service")
if [[ -n "${CLOUD_RUN_SERVICE:-}" ]]; then
  SERVICES=("${CLOUD_RUN_SERVICE}")
fi

for svc in "${SERVICES[@]}"; do
  case "${svc}" in
    accounts|billing-service|content-service) ;;
    *) echo "Unsupported Cloud Run service: ${svc}" >&2; exit 2 ;;
  esac
done

echo "==> [Cloud Run] Deploying backend microservices to GCP project: ${GCP_PROJECT} (region: ${GCP_REGION}, environment: ${DEPLOY_ENV})..."

for svc in "${SERVICES[@]}"; do
  SERVICE_NAME="${DEPLOY_ENV}-${svc}"
  IMAGE_URI="${GCP_ARTIFACT_REGISTRY_REGION}-docker.pkg.dev/${GCP_PROJECT}/serverless/${svc}:${IMAGE_TAG}"

  env_vars=(
    "APP_ENV=${DEPLOY_ENV}"
    "ENV=${DEPLOY_ENV}"
    # Cloud Run uses the Supabase connection URI directly.  DATABASE_URL plus
    # DB_TLS_HOST/DB_TLS_PORT is the legacy VPS/stunnel contract and must not
    # be emitted by this deployment path.
    "SUPABASE_CONNECT_URI=${SUPABASE_CONNECT_URI}"
    "INTERNAL_SERVICE_TOKEN=${INTERNAL_SERVICE_TOKEN}"
  )
  case "${svc}" in
    accounts)
      env_vars+=(
        "CONFIG_TEMPLATE=${CONFIG_TEMPLATE:-/app/config/account.cloudrun.yaml}"
        "ROOT_BOOTSTRAP_EMAIL=${ROOT_BOOTSTRAP_EMAIL:?ROOT_BOOTSTRAP_EMAIL is required}"
        "ROOT_BOOTSTRAP_PASSWORD=${ROOT_BOOTSTRAP_PASSWORD:?ROOT_BOOTSTRAP_PASSWORD is required from Vault}"
        "AUTH_TOKEN_PUBLIC_TOKEN=${AUTH_TOKEN_PUBLIC_TOKEN:?AUTH_TOKEN_PUBLIC_TOKEN is required from Vault}"
        "AUTH_TOKEN_REFRESH_SECRET=${AUTH_TOKEN_REFRESH_SECRET:?AUTH_TOKEN_REFRESH_SECRET is required from Vault}"
        "AUTH_TOKEN_ACCESS_SECRET=${AUTH_TOKEN_ACCESS_SECRET:?AUTH_TOKEN_ACCESS_SECRET is required from Vault}"
        "XWORKMATE_SHARED_TENANT_DOMAIN=${XWORKMATE_SHARED_TENANT_DOMAIN:?XWORKMATE_SHARED_TENANT_DOMAIN is required}"
        "XWORKMATE_SHARED_TENANT_DOMAINS=${XWORKMATE_SHARED_TENANT_DOMAINS:-${XWORKMATE_SHARED_TENANT_DOMAIN}}"
        "XWORKMATE_BRIDGE_SERVER_URL=${XWORKMATE_BRIDGE_SERVER_URL:?XWORKMATE_BRIDGE_SERVER_URL is required}"
        "SMTP_HOST=${SMTP_HOST:-smtp.qq.com}"
        "SMTP_PORT=${SMTP_PORT:-587}"
        "SMTP_FROM=${SMTP_FROM:-XControl Account <no-reply@example.com>}"
      )
      ;;
    content-service)
      env_vars+=(
        "KNOWLEDGE_REPO_PATH=${KNOWLEDGE_REPO_PATH:?KNOWLEDGE_REPO_PATH is required from Vault}"
        "KNOWLEDGE_REPO_URL=${KNOWLEDGE_REPO_URL:-https://github.com/ai-workspace-services/knowledge.git}"
        "KNOWLEDGE_REPO_REF=${KNOWLEDGE_REPO_REF:-main}"
      )
      ;;
    billing-service)
      env_vars+=("BILLING_INGEST_MODE=${BILLING_INGEST_MODE:-push}")
      ;;
  esac
  env_delimiter=""
  for candidate in '|' ';' '%' '~' '^' '+' ':'; do
    candidate_used=false
    for env_var in "${env_vars[@]}"; do
      if [[ "${env_var}" == *"${candidate}"* ]]; then
        candidate_used=true
        break
      fi
    done
    if [[ "${candidate_used}" == false ]]; then
      env_delimiter="${candidate}"
      break
    fi
  done
  if [[ -z "${env_delimiter}" ]]; then
    echo "Unable to choose a safe gcloud env-var delimiter" >&2
    exit 1
  fi
  env_vars_joined="$(IFS="${env_delimiter}"; printf '%s' "${env_vars[*]}")"

  echo "==> [Cloud Run] Deploying ${SERVICE_NAME} (min=0, max=2)..."
  
  # Deploy and inject the service-specific runtime contract.
  gcloud run deploy "${SERVICE_NAME}" \
    --project="${GCP_PROJECT}" \
    --region="${GCP_REGION}" \
    --image="${IMAGE_URI}" \
    --platform=managed \
    --allow-unauthenticated \
    --min-instances=0 \
    --max-instances=2 \
    --cpu=1 \
    --memory=512Mi \
    --set-env-vars="^${env_delimiter}^${env_vars_joined}" \
    --quiet
done

echo "==> [Cloud Run] Backend microservices deployment finished."
