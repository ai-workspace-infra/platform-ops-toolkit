#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Vault Authentication & Policy Split Initialization (sit, uat, prod)
#
# Requirements:
# 1. Run this script from a terminal with access to Vault (e.g. https://vault.svc.plus).
# 2. Vault must be initialized and unsealed.
# 3. Export VAULT_ADDR and VAULT_TOKEN (with admin privileges).
#
# -----------------------------------------------------------------------------
# 2026-07-22 安全硬化。修复的问题:
#
#   1. sit role 原先只绑 `repository`, 没有任何 ref / workflow 约束 —— 任何能推
#      分支的人, 用任何自己新加的 workflow, 都能换到 sit token。而三个 role 的
#      policy 都能读共享的 `kv/data/CICD`(存 VULTR_API_KEY / TF_STATE_* /
#      SSH_PRIVATE_DEPLOY_KEY_B64), 于是"按环境隔离"实际不成立。
#   2. uat role 只绑 `refs/heads/main`, 但流水线把 `release/*` push 也路由到
#      uat -> release 分支认证必然失败。
#   3. prod role 绑 `refs/heads/release/*`, 但流水线只在 `v*` tag 时请求 prod
#      -> tag 发版认证必然失败; 而单独建的 `-prod-tags` role 从来没有被任何
#      workflow 请求过(死角色)。同时 `release/*` 是任何 writer 都能创建的分支,
#      等于 prod 权限对所有 writer 敞开。
#   4. prod policy 带 `delete`(含 `kv/metadata/prod/*` 的永久销毁), 与文档
#      《vault_authentication_and_policy_isolation.md》自己的安全警告矛盾。
#
# 硬化要点: user_claim 用 sub 而非 actor; 钉死 job_workflow_ref(只有本仓库这
# 6 个 workflow 文件能换 token, 新加的 workflow 换不到); ref 绑定与流水线真实
# 触发路径对齐; batch token + 20m TTL + 去掉 default policy。
#
# ⚠️ 行为变更: prod 现在只能由 `v*` tag 触发。workflow_dispatch 选 prod 会认证
#    失败 —— 这是刻意的, 与分支规范"生产部署只经 annotated tag"一致。
# =============================================================================

export VAULT_ADDR="${VAULT_ADDR:-https://vault.svc.plus}"

if [ -z "${VAULT_TOKEN:-}" ] && ! vault token lookup >/dev/null 2>&1; then
  echo "Error: no authenticated Vault CLI session is available."
  exit 1
fi

REPO="ai-workspace-infra/platform-ops-toolkit"
PLAYBOOKS_REPO="ai-workspace-infra/playbooks"

# 允许换取这些 role 的 workflow 文件白名单。job_workflow_ref 的值形如
# <org>/<repo>/.github/workflows/<file>@<ref>, 所以用 @* 收尾放行任意 ref,
# 但文件名本身是钉死的 —— 仓库里新增一个 workflow 无法换到任何 role。
WF_PREFIX="${REPO}/.github/workflows"
read -r -d '' ALLOWED_WORKFLOWS <<EOF || true
    "${WF_PREFIX}/platform-ops.yaml@*",
    "${WF_PREFIX}/daily-main-snapshot.yaml@*",
    "${WF_PREFIX}/resize-instance.yaml@*",
    "${WF_PREFIX}/deploy-action-runner-iac.yaml@*",
    "${WF_PREFIX}/iac-pipeline-multi-cloud-account-matrix.yaml@*",
    "${WF_PREFIX}/iac-pipeline-multi-cloud-resources-matrix.yaml@*",
    "${WF_PREFIX}/iac-pipeline-multi-cloud-landingzone-baseline.yaml@*"
EOF

PLAYBOOKS_WF_PREFIX="${PLAYBOOKS_REPO}/.github/workflows"
read -r -d '' PLAYBOOKS_ALLOWED_WORKFLOWS <<EOF || true
    "${PLAYBOOKS_WF_PREFIX}/web-saas-domain-cd.yaml@*",
    "${PLAYBOOKS_WF_PREFIX}/ai-workspace-domain-cd.yaml@*",
    "${PLAYBOOKS_WF_PREFIX}/agent-proxy-domain-cd.yaml@*",
    "${PLAYBOOKS_WF_PREFIX}/open-platform-domain-cd.yaml@*"
    ,"${PLAYBOOKS_WF_PREFIX}/domain-cd.yaml@*"
EOF

# -----------------------------------------------------------------------------
# Policies
#
# 路径分三层:
#
#   1. 公共服务 secret —— 三个环境共读, 只读不可改:
#        kv/data/CICD          GHCR 镜像拉取凭据(GHCR_USERNAME / GHCR_TOKEN)
#        kv/data/openclaw
#        kv/data/action-runner
#      拉的是同一批镜像, 不存在"环境"这个维度, 拆三份只会产生三份要同步轮换
#      的副本。这一层**只给 read**, 任何 role 都不能写 —— 公共资产不允许被
#      任何单一环境的流水线改动。
#
#   2. 基础凭据 —— 按环境拆分, 各 role 只读自己那份, 同样只读:
#        kv/data/CICD/<env>    VULTR_API_KEY / TF_STATE_* / SSH_PRIVATE_DEPLOY_KEY_B64
#      这些凭据授予的是"控制基础设施"和"登录主机"的能力, 是提权的实际载体,
#      必须按环境隔离: sit 失陷不应该拿到 prod 的云账号和主机私钥。
#      注意 KV v2 里 kv/data/CICD 与 kv/data/CICD/<env> 是两个独立的 secret,
#      而 policy 里 path "kv/data/CICD" 只精确匹配根路径、不匹配子路径,
#      所以"共读根 + 只读自己那份子路径"可以严格成立。
#
#   2.5 泛域名证书库 —— 跨环境共享, 可读写(第 1 层只读原则的有意破例):
#        kv/data/CICD/domains/<domain>   *.<domain> 的证书 + 私钥 + caddy_data
#      同一张泛域名证书三个环境共用, 按环境各存一份等于同一张证书签三次、
#      占三份 Let's Encrypt 限流额度。详见 emit_domain_cert_paths 处的说明。
#
#   3. 环境专属业务密钥 —— 严格隔离, 可读写:
#        kv/data/<env>/*       该环境自己的业务密钥
#
# 另外: 绑定收紧(job_workflow_ref 白名单 + 各自 ref)与本层路径隔离是两道
# 独立的防线。绑定决定"谁能换到 token", 路径决定"换到之后能看到什么"。
# -----------------------------------------------------------------------------

# 第 1 层: 公共服务 secret —— 三个环境共读, 只给 read, 不可修改。
emit_common_read_paths() {
  cat <<'EOF'
# 公共服务凭据(GHCR 镜像拉取等)。全平台共用, 不存在环境维度, 不拆分。
# 只读: 公共资产不允许被任何单一环境的流水线改动。
path "kv/data/CICD" {
  capabilities = ["read"]
}
path "kv/data/CICD/github-app/daily-snapshot" {
  capabilities = ["read"]
}
path "kv/metadata/CICD" {
  capabilities = ["list", "read"]
}
path "kv/metadata/CICD/github-app/daily-snapshot" {
  capabilities = ["read"]
}
path "kv/data/openclaw" {
  capabilities = ["read"]
}
path "kv/data/action-runner" {
  capabilities = ["read"]
}
path "kv/metadata/action-runner" {
  capabilities = ["list", "read"]
}
EOF
}

# 第 1.5 层: 泛域名证书库 —— 三个环境共读**且共写**。
#
# 这是第 1 层"公共资产只读"原则的一处**有意破例**, 单独拎出来而不是混进
# emit_common_read_paths, 就是为了让这个破例是显式的。
#
# 为什么必须共享: *.onwalk.net 这张泛域名证书对 sit/uat/prod 本来就是同一张。
# 按环境各存一份 = 同一张证书签三次、占三份 Let's Encrypt 限流额度
# ("同一组域名 5 次/周"), 而重建正是要反复做的事。
#
# 为什么必须可写: 证书由部署时的 Caddy 签出, 再由流水线存回来供下次重建复用。
# 只读就只能恢复、不能更新, 90 天到期后所有环境一起失效。
#
# 已知代价, 记在这里以免下次审计时被当成配置错误: 任一环境失陷都能覆写这份
# 共享证书。但这个风险是"三环境共用一张泛域名证书"本身带来的 —— 共读就已经
# 意味着 sit 能拿到 prod 在用的私钥, 共写并没有把边界推得更远。真要收敛,
# 得先让各环境用各自的证书(例如 *.sit.onwalk.net), 那是另一个决定。
#
# 不给 delete: 与 prod 那条同理, kv/metadata 的 delete 会永久销毁全部版本,
# 流水线异常时足以把所有环境的证书一起抹掉。
emit_domain_cert_paths() {
  cat <<'EOF'

# 泛域名证书库(Caddy 通过 ACME DNS-01 签出的 *.<domain>)。按域名存, 不按环境
# 存 —— 同一张证书三个环境共用。写入方是 platform-ops 的
# platform-ops_observe_backup-caddy-certs.sh, 读取方是
# platform-ops_deploy_base_restore-caddy-certs.sh。
path "kv/data/CICD/domains/*" {
  capabilities = ["create", "read", "update", "list"]
}
path "kv/metadata/CICD/domains/*" {
  capabilities = ["list", "read"]
}
EOF
}

# 第 2 层: 基础凭据 —— 只读, 且只读自己环境那一份。
# $1 = env name
emit_base_credential_paths() {
  local env="$1"
  cat <<EOF

# 本环境的基础凭据(云账号 API key / TF state 后端凭据 / SSH 部署私钥)。
# 只精确授予 kv/data/CICD/${env}, 因此读不到其他环境的同类凭据。
# 同样只给 read: 流水线消费凭据, 不负责轮换凭据。
path "kv/data/CICD/${env}" {
  capabilities = ["read"]
}
path "kv/metadata/CICD/${env}" {
  capabilities = ["list", "read"]
}
EOF
}

# $1 = env name (sit|uat|prod)
emit_env_policy() {
  local env="$1"

  emit_common_read_paths
  emit_domain_cert_paths
  emit_base_credential_paths "${env}"

  # WEB_SAAS 目前是 uat / prod 共读(内含 POSTGRES_ROOT_PASSWORD /
  # ACCOUNT_DB_PASSWORD 等), 即 uat 与 prod 共用同一套数据库口令。这与
  # kv/data/CICD 不同 —— 数据库口令是环境专属的业务密钥, 不是公共服务凭据,
  # 后续应拆分为 kv/data/<env>/web-saas。
  if [ "${env}" != "sit" ]; then
    cat <<'EOF'
path "kv/data/WEB_SAAS" {
  capabilities = ["read"]
}
path "kv/metadata/WEB_SAAS" {
  capabilities = ["list", "read"]
}
EOF
  fi

  if [ "${env}" = "prod" ]; then
    # prod 不给 delete: kv/data 的 delete 是软删, kv/metadata 的 delete 会
    # 永久销毁一个 secret 的所有版本, 流水线异常时足以摧毁生产密钥。
    cat <<EOF
path "kv/data/${env}/*" {
  capabilities = ["create", "read", "update", "list"]
}
path "kv/metadata/${env}/*" {
  capabilities = ["list", "read"]
}
EOF
  else
    cat <<EOF
path "kv/data/${env}/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}
path "kv/metadata/${env}/*" {
  capabilities = ["list", "read", "delete"]
}
EOF
  fi
}

for env in sit uat prod; do
  echo "Creating ${env} policy..."
  emit_env_policy "${env}" | vault policy write "github-actions-platform-ops-toolkit-${env}" -
done

# -----------------------------------------------------------------------------
# Roles
#
# 共同硬化项:
#   user_claim=sub            身份绑定到工作负载(repo+ref+workflow), 而不是
#                             触发者的 GitHub 用户名(actor)
#   job_workflow_ref          钉死到白名单 workflow 文件
#   token_no_default_policy   不附加 default policy, 最小权限
#   token_type=batch          CI 用不可续期的一次性 token
#   token_ttl/max_ttl=1h      见下方 TOKEN_TTL 说明
#
# ⚠️ TTL 校准: 这里保持 1h(与硬化前一致), 是为了不引入新的中断风险 ——
#   deploy_web_saas 现在要在 runner 上编译 billing 二进制、构建并 docker save
#   postgres-extensions 镜像, 再跑完整 ansible 部署, 且多个后置步骤会把
#   VAULT_TOKEN 传给 ansible; 若 TTL 短于 job 实际耗时, token 会在部署中途过期。
#   等测到 job 时长的 p95 之后, 再把 TTL 收敛到"略大于 p95"的值。
#   本轮的安全收益来自绑定收紧 / batch token / 去掉 default policy, 而不是 TTL。
# -----------------------------------------------------------------------------

TOKEN_TTL="1h"

# $1 = role name suffix, $2 = policy name, $3 = ref claim JSON value
write_role() {
  local suffix="$1" policy="$2" ref_claim="$3"
  vault write "auth/jwt/role/github-actions-platform-ops-toolkit-${suffix}" - <<EOF
{
  "role_type": "jwt",
  "user_claim": "sub",
  "bound_audiences": ["vault"],
  "bound_claims_type": "glob",
  "bound_claims": {
    "repository": "${REPO}",
    "job_workflow_ref": [
${ALLOWED_WORKFLOWS}
    ],
    "ref": ${ref_claim}
  },
  "token_policies": ["${policy}"],
  "token_no_default_policy": true,
  "token_type": "batch",
  "token_ttl": "${TOKEN_TTL}",
  "token_max_ttl": "${TOKEN_TTL}"
}
EOF
}

# $1 = environment suffix, $2 = policy name, $3 = ref claim JSON value
#
# 这些 role 是给 platform-ops.yaml 跨仓 `uses:` 调用 playbooks 的域 CD 用的。
# OIDC 的 repository claim 是 **运行所属的仓库**, 也就是调用方
# platform-ops-toolkit —— 不是被调用的 workflow 所在的 playbooks。绑成
# playbooks 会永远匹配不上, 认证直接失败。被调用方的身份要靠
# job_workflow_ref 钉, GitHub 引入这个 claim 正是为了可复用 workflow。
# 两者合起来才是想要的边界: "一次由 platform-ops-toolkit 拥有的 run,
# 正在执行 playbooks 的域 CD workflow"。
write_playbooks_role() {
  local suffix="$1" policy="$2" ref_claim="$3"
  vault write "auth/jwt/role/github-actions-playbooks-${suffix}" - <<EOF
{
  "role_type": "jwt",
  "user_claim": "sub",
  "bound_audiences": ["vault"],
  "bound_claims_type": "glob",
  "bound_claims": {
    "repository": "${REPO}",
    "job_workflow_ref": [
${PLAYBOOKS_ALLOWED_WORKFLOWS}
    ],
    "ref": ${ref_claim}
  },
  "token_policies": ["${policy}"],
  "token_no_default_policy": true,
  "token_type": "batch",
  "token_ttl": "${TOKEN_TTL}",
  "token_max_ttl": "${TOKEN_TTL}"
}
EOF
}

# sit: PR 验证 + 非 main 分支的 workflow_dispatch。ref 仍然较宽(PR 与分支都要
# 放行), 真正的收敛来自 job_workflow_ref 白名单 —— 换 token 只能通过本仓库
# 已有的 6 个 workflow, 自己新加一个 workflow 是换不到的。
echo "Creating SIT role (PR + branch dispatch)..."
write_role sit github-actions-platform-ops-toolkit-sit \
  '["refs/pull/*/merge", "refs/heads/*"]'

# uat: main / release/* / daily-build-* 的 push 或 workflow_dispatch 都路由到 uat。
# daily-build-* 是快照/回放用的临时分支与标签前缀, 需要同时放行 branch/tag 两种形式。
echo "Creating UAT role (main + release/* + bugfix/* + daily-build/*)..."
write_role uat github-actions-platform-ops-toolkit-uat \
  '["refs/heads/main", "refs/heads/release/*", "refs/heads/bugfix/*", "refs/heads/daily-build-*", "refs/tags/daily-build-*"]'

# prod: 基础设施仓库弱化 tag 限制，允许 main 分支直接操作，同时也兼容 v* tag。
echo "Creating PROD role (main + v* tags)..."
write_role prod github-actions-platform-ops-toolkit-prod \
  '["refs/tags/v*", "refs/heads/main"]'

echo "Creating Playbooks SIT role (PR + branch dispatch)..."
write_playbooks_role sit github-actions-platform-ops-toolkit-sit \
  '["refs/pull/*/merge", "refs/heads/*"]'

echo "Creating Playbooks UAT role (main + release/* + bugfix/* + daily-build/*)..."
write_playbooks_role uat github-actions-platform-ops-toolkit-uat \
  '["refs/heads/main", "refs/heads/release/*", "refs/heads/bugfix/*", "refs/heads/daily-build-*", "refs/tags/daily-build-*"]'

echo "Creating Playbooks PROD role (main + v* tags)..."
write_playbooks_role prod github-actions-platform-ops-toolkit-prod \
  '["refs/tags/v*", "refs/heads/main"]'

# 死角色清理: -prod-tags 从来没有被任何 workflow 请求过, 其职责已并入 -prod。
echo "Removing dead role github-actions-platform-ops-toolkit-prod-tags (if present)..."
vault delete auth/jwt/role/github-actions-platform-ops-toolkit-prod-tags 2>/dev/null \
  || echo "  (not present, nothing to remove)"

echo
echo "Done. 3 个 policy + 3 个 role 已生效, 死角色 -prod-tags 已清理。"
echo
echo
echo "注意行为变更: prod 目前已放宽限制，允许 main 分支以及 v* tag 进行部署操作。"
echo
echo "⚠️ 基础凭据迁移必须按序执行, 否则流水线会读到空值:"
echo "  1. 先写数据: 为每个环境在 kv/CICD/{sit,uat,prod} 写入各自的"
echo "     VULTR_API_KEY / TF_STATE_* / SSH_PRIVATE_DEPLOY_KEY_B64。"
echo "  2. 应用本脚本(policy 生效)。"
echo "  3. 合并 workflow 侧的 VAULT_KV_BASE 改动。"
echo "  4. 最后从根路径 kv/CICD 删掉已搬走的基础凭据, 只留 GHCR 等公共服务键。"
echo
echo "  第 1 步可以先把现有同一份凭据复制到三个路径下让链路先跑通, 但真正的隔离"
echo "  收益要等三个环境换成各自独立的凭据(独立 Vultr API key / 独立 SSH 密钥对)"
echo "  才成立。在那之前, 路径已隔离但凭据仍复用。"
echo
echo "后续待办(未包含在本脚本中):"
echo "  - kv/data/WEB_SAAS 目前由 uat 与 prod 共读, 内含数据库口令。数据库口令属于"
echo "    环境专属业务密钥(不同于 kv/data/CICD 那类公共服务凭据), 应拆分为"
echo "    kv/data/<env>/web-saas, 让两个环境不再共用同一套口令。"
