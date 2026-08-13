#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# 业务服务仓的 Vault JWT role（accounts / billing-service / console /
# content-service /
# postgresql）。
#
# 这些仓库**只跑 CI**：构建镜像并推到 GHCR。部署由 GitOps 侧完成 ——
# Doco-CD（或未来的 K3s/K8s reconciler）从 gitops 仓拉取。SSH/Ansible 只用于
# 主机初始化与非容器化服务，不用于交付应用代码。
#
# 权限因此收敛到一件事：读 GHCR 推送凭据。
#
# -----------------------------------------------------------------------------
# ⚠️ 与草案版本的差异，以及为什么
#
# 1. **不授予 github-actions-platform-ops-toolkit-<env> policy。**
#    那个 policy 能读 kv/data/CICD/<env>，内含 VULTR_API_KEY（可创建/销毁
#    主机）、TF_STATE_*（state 后端凭据）、SSH_PRIVATE_DEPLOY_KEY_B64
#    （全主机部署私钥）。把它给业务仓的 CI 意味着：任何能改 accounts 仓
#    workflow 的人，都能拿到 UAT 的云账号和主机 SSH 私钥。
#    这与"业务仓不 SSH 到主机"的边界直接矛盾，也是本仓库
#    vault_auth_split.sh 顶部记录的那类提权路径（sit role 曾能读共享的
#    kv/data/CICD，使环境隔离形同虚设）。
#
# 2. **每个服务一个专属 policy，只读 kv/data/CICD。**
#    草案在 token_policies 里引用了 github-actions-<service>，但从未创建
#    它。Vault 接受不存在的 policy 名——token 签发成功，那部分权限静默
#    为空。缺失的授权表现为运行时 403，而不是配置时报错。
#
# 3. **UAT 不放行 refs/heads/bugfix/*。**
#    bugfix/* 是任何 writer 都能创建的分支。放行它等于把 UAT 凭据边界
#    降到"有 push 权限即可"。要在分支上验证 CI，用 sit role
#    （它本就放行 refs/heads/*，且只能读公共服务凭据）。
#
# 4. **不硬编码 VAULT_TOKEN。** 见下方注释。
# -----------------------------------------------------------------------------

export VAULT_ADDR="${VAULT_ADDR:-https://vault.svc.plus}"

# admin token 只从环境变量或已有 CLI 会话取，绝不写进文件。
# 写进脚本的 token 会进入 git 历史，而 git 历史里的密钥无法靠"下一个 commit
# 删掉"来撤销——只能轮换 + git filter-repo 重写历史 + 强制推送。
# 规范见 skill engineering-standards/multi-environment-delivery-and-release §5。
if [ -z "${VAULT_TOKEN:-}" ] && ! vault token lookup >/dev/null 2>&1; then
  echo "Error: no authenticated Vault CLI session is available." >&2
  echo "  export VAULT_TOKEN=hvs.xxx   (admin token, do NOT commit it)" >&2
  exit 1
fi

TOKEN_TTL="1h"

# -----------------------------------------------------------------------------
# Policy：每个服务一份，只读 GHCR 推送凭据。
#
# kv/data/CICD 是第 ① 层公共服务 secret（GHCR_USERNAME / GHCR_TOKEN）——
# 拉推的是同一批镜像，不存在环境维度。只给 read：流水线消费凭据，不负责
# 轮换凭据。
#
# KV v2 里 kv/data/CICD 与 kv/data/CICD/<env> 是两个独立 secret，且 policy
# 中 path "kv/data/CICD" 只精确匹配根路径、不匹配子路径。所以这份 policy
# 读不到任何环境的基础凭据——这正是它与 toolkit policy 的关键差别。
# -----------------------------------------------------------------------------
write_service_policy() {
  local service="$1"
  vault policy write "github-actions-${service}" - <<'EOF'
# 公共服务凭据: GHCR 镜像推送 (GHCR_USERNAME / GHCR_TOKEN)。
# 只读, 且只有这一条路径 —— 业务仓 CI 不需要云账号、TF state 或主机私钥。
path "kv/data/CICD" {
  capabilities = ["read"]
}
path "kv/metadata/CICD" {
  capabilities = ["list", "read"]
}
EOF
}

# -----------------------------------------------------------------------------
# Role
#
# 硬化项与 vault_auth_split.sh 保持一致：
#   user_claim=sub            身份绑到工作负载(repo+ref+workflow), 而非触发者
#   job_workflow_ref          钉死到该仓库的 pipeline 文件, 新加 workflow
#                             换不到 token
#   token_no_default_policy   不附加 default policy
#   token_type=batch          CI 用不可续期 token
# -----------------------------------------------------------------------------
# $1=service $2=env suffix $3=ref claim JSON $4=repository
# $5=workflow glob (optional; defaults to the service CI pipeline convention)
write_role() {
  local service="$1" suffix="$2" ref_claim="$3" repo="$4"
  local workflow_glob="${5:-${repo}/.github/workflows/*pipeline.ym*@*}"
  echo "  role github-actions-${service}-${suffix}  <- ${repo}"
  vault write "auth/jwt/role/github-actions-${service}-${suffix}" - <<EOF
{
  "role_type": "jwt",
  "user_claim": "sub",
  "bound_audiences": ["vault"],
  "bound_claims_type": "glob",
  "bound_claims": {
    "repository": "${repo}",
    "job_workflow_ref": "${workflow_glob}",
    "ref": ${ref_claim}
  },
  "token_policies": ["github-actions-${service}"],
  "token_no_default_policy": true,
  "token_type": "batch",
  "token_ttl": "${TOKEN_TTL}",
  "token_max_ttl": "${TOKEN_TTL}"
}
EOF
}

# $1=service $2=repository
process_repo() {
  local service="$1" repo="$2"
  echo "=== ${service} (${repo})"
  write_service_policy "${service}"

  # sit: PR、任意分支和 sit-* tag。收敛来自 job_workflow_ref 白名单 + 这份 policy 本身
  # 只能读公共服务凭据 —— 换到 sit token 也拿不到任何环境的基础凭据。
  write_role "${service}" sit '["refs/pull/*/merge", "refs/heads/*", "refs/tags/sit-*"]' "${repo}"

  # uat: main、release/*、daily-build-* 分支与受限的 UAT snapshot tags。
  # daily-build-* 分支是 snapshot dispatch 的临时工作分支，只放行这一类命名，
  # 不放行任意 feature/bugfix 分支。
  write_role "${service}" uat '["refs/heads/main", "refs/heads/release/*", "refs/heads/daily-build-*", "refs/tags/uat-*", "refs/tags/daily-build-*"]' "${repo}"

  # prod: release v* 与显式 prod-* tag。
  write_role "${service}" prod '["refs/tags/v*", "refs/tags/prod-*"]' "${repo}"
}

# gitops is a deployment-consumer repository rather than a service image
# producer, but its PR guard still needs read-only GHCR credentials to verify
# every image declared in compose. Its workflow name is intentionally explicit
# and must be bound separately from the service CI pipeline convention.
process_gitops_repo() {
  local repo="ai-workspace-infra/gitops"
  local workflow="${repo}/.github/workflows/validate-release-pr.yml@*"
  echo "=== gitops (${repo})"
  write_service_policy gitops

  write_role gitops sit '"refs/pull/*/merge"' "${repo}" "${workflow}"
  write_role gitops uat '"refs/heads/main"' "${repo}" "${workflow}"
  write_role gitops prod '"refs/tags/v*"' "${repo}" "${workflow}"
}

process_repo accounts         ai-workspace-services/accounts
process_repo billing-service  ai-workspace-services/billing-service
process_repo console          ai-workspace-services/portal
process_repo content-service  ai-workspace-services/content-service
process_repo postgresql       ai-workspace-infra/postgresql.svc.plus
process_gitops_repo

cat <<'EOF'

Done. 5 个服务与 gitops 各创建了 1 个 policy + 3 个 role。

每个 role 只能读 kv/data/CICD（GHCR 凭据），读不到任何 kv/data/CICD/<env>
下的云账号 / TF state / SSH 私钥。

验证任一 role 的绑定与授权：
  vault read auth/jwt/role/github-actions-accounts-uat
  vault policy read github-actions-accounts

若某个仓库的 CI 报 403，先确认它请求的路径是否真的属于本层 ——
业务仓 CI 需要基础凭据，通常意味着它还在做本该由 CD 做的事。
EOF
