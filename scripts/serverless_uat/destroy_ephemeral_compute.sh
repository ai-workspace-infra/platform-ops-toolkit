#!/usr/bin/env bash
set -euo pipefail

# -----------------------------------------------------------------------------
# UAT 临时计算资源夜间彻底销毁与旧镜像清理脚本
# 仅删除 Cloud Run 临时服务，Supabase 数据库与 Cloudflare Pages 永久保留
# -----------------------------------------------------------------------------

GCP_PROJECT="${GCP_PROJECT_ID:-ai-workspace-uat-project}"
GCP_REGION="${GCP_REGION:-asia-east1}"

SERVICES=("accounts" "billing-service" "content-service")

echo "==> [UAT Teardown] Destroying ephemeral Cloud Run compute services in project ${GCP_PROJECT}..."

for svc in "${SERVICES[@]}"; do
  SERVICE_NAME="uat-${svc}"
  echo "==> [Cloud Run] Deleting ${SERVICE_NAME}..."
  gcloud run services delete "${SERVICE_NAME}" \
    --project="${GCP_PROJECT}" \
    --region="${GCP_REGION}" \
    --quiet || {
      echo "Notice: Service ${SERVICE_NAME} was not active or already deleted."
    }
done

echo "==> [Cleanup] Pruning older container image tags in Artifact Registry..."
gcloud artifacts docker images list "asia-east1-docker.pkg.dev/${GCP_PROJECT}/serverless" \
  --project="${GCP_PROJECT}" \
  --filter="createTime < -P2D" \
  --format="value(IMAGE)" 2>/dev/null | xargs -r -n 1 gcloud artifacts docker images delete --quiet || true

echo "==> [Success] Ephemeral UAT compute teardown finished. Persistent stores intact."
