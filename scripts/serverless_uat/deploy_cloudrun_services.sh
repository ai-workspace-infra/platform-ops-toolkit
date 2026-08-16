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

  echo "==> [Cloud Run] Deploying ${SERVICE_NAME} (min=0, max=2)..."
  
  # 部署并注入 Supabase 数据库连接串与 JWT 密钥
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
    --set-env-vars="ENV=${DEPLOY_ENV},DATABASE_URL=${DATABASE_URL:-},JWT_SECRET=${JWT_SECRET:-}" \
    --quiet
done

echo "==> [Cloud Run] Backend microservices deployment finished."
