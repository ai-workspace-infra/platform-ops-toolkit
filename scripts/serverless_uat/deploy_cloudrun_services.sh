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
    "SUPABASE_CONNECT_URI=${SUPABASE_CONNECT_URI}"
    "INTERNAL_SERVICE_TOKEN=${INTERNAL_SERVICE_TOKEN}"
  )
  case "${svc}" in
    accounts)
      env_vars+=(
        "CONFIG_TEMPLATE=${CONFIG_TEMPLATE:-/app/config/account.cloudrun.yaml}"
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
  env_vars_joined="$(IFS='@'; printf '%s' "${env_vars[*]}")"

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
    --set-env-vars="^@^${env_vars_joined}" \
    --quiet
done

echo "==> [Cloud Run] Backend microservices deployment finished."
