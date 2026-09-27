# XConnect + Vault 迁移、部署、扩缩容与回滚运行手册

## 1. 文档目的

这份手册把 `vault.svc.plus` 从历史节点迁移到 GCP、建立 XConnect 数据面、部署 Vault Raft、执行一节点与三节点扩缩容、切换 DNS 以及回滚的过程串成一条可重复执行的流程。

手册适用于：

- 旧 Vault 保留为独立 server，GCP Vault 作为新服务入口；
- XConnect Gateway/One 通过 WireGuard over VLESS 提供 Raft 和运维数据面；
- Vault 使用本地 Integrated Storage（Raft），目标规模为 1 或 3 个节点；
- GitHub Actions 负责声明解析、IaC、Playbook 编排和只读验收，初始化、unseal 和最终流量决策由受控运维会话完成。

本手册不把 token、unseal share、私钥、邀请 URI 或 age 私钥写入 Git、Actions 日志、inventory 或文档。

## 2. 当前实例的最终状态

本次迁移后的稳定状态如下：

| 项目 | 当前值 |
| --- | --- |
| 服务域名 | `vault.svc.plus` |
| GCP 项目 | `open-platform-prod` |
| GCP 网络 | `vault-shared` |
| 当前 GCP 节点 | `vault-prod-0`，`RUNNING` |
| GCP 地址 | 私网 `10.81.0.4`，公网 `35.221.167.104` |
| Vault | 1.21.4，Raft，initialized，unsealed，active leader |
| 当前 Raft 规模 | 1 个 voter/leader |
| 旧节点 | `46.250.251.132`，`vault-2`，独立 Vault server，已暂停容器观察 |
| DNS | `vault.svc.plus` 仅返回 `35.221.167.104` |
| XConnect Gateway | `10.79.0.1` |

旧节点和 GCP 节点由同一个 Raft snapshot 产生过相同 `cluster_id`。因此两套 server 不能同时接受写流量；任何回滚都必须先把 DNS 指回单一入口，并停止另一套写入口。

## 3. 架构和边界

```text
                         控制面
                 Accounts API / XConnect Zero
                      策略、设备、配置分发
                              |
                              v
      旧节点 46.250.251.132          GCP vault-prod-0
              |                         |
              | WireGuard over VLESS    | Gateway
              +-------- XConnect -------+ 10.79.0.1
                         数据面
                              |
                   Vault Raft TCP 8200/8201
                              |
                    vault.svc.plus / Caddy TLS
```

### 3.1 XConnect 控制面与数据面

- 控制面负责创建网络、签发一次性邀请、分发签名配置、同步 peer 和撤销设备。
- 数据面是 Gateway/One 上的 WireGuard peer 和本地 Xray/Caddy 传输链路；控制面短暂不可用时，已建立的数据面仍可继续转发。
- 公网只承载受保护的 VLESS/TLS TCP 443；WireGuard UDP 51820 不直接暴露公网。
- Gateway 的 Caddy TLS 入口把 `/xconnect` 转发到本地 Xray socket，再由 Xray 转到 Gateway 的 WireGuard 数据面。
- Vault Raft 的 8200/8201 只允许私有网络或 XConnect overlay 到达，不能暴露到公网。

### 3.2 Vault 控制边界

- Playbook 只安装和配置 Vault，不执行 `vault operator init`、`vault operator unseal`，也不读取或写入 root token/unseal share。
- GitHub Actions 不持有 root token、unseal share、operator token 或 age 私钥。
- DNS 切换、Raft leader 转移、旧 peer 移除和回滚必须使用明确的确认短语，并由 `prod` Environment 审批保护。

## 4. 变更前准备

### 4.1 必须具备的声明

在 GitOps 中准备以下声明，并记录使用的完整 commit SHA：

1. Provider-neutral Vault 服务声明：
   - `storage.backend: raft`
   - `storage.members: 1` 或 `3`
   - `storage.leader` 与 `storage.peers` 与节点列表一致
   - `storage.address_scope: private`
   - `migration.raft_network: private` 或 `overlay`
   - 旧节点的固定 ID、SSH host key、overlay address
2. GCP shared 资源声明：
   - 项目 `open-platform-prod`
   - 网络 `vault-shared`
   - 子网 `10.81.0.0/20`
   - `vault-prod-0` 单节点，或 `vault-prod-0/1/2` 三节点
   - OS Login、SSH `/32` 白名单、Raft 私网防火墙
3. XConnect topology：
   - Gateway ID、WireGuard public key、overlay IP 和 endpoint
   - 三节点扩容模板中的 `fixed_nodes`
   - 操作 Mac 的设备 ID 和 overlay IP

生产 provider 文件里保留的三节点列表可以作为扩容模板，但不能代替 shared live 资源声明。扩容前要显式核对网络、子网、机型和 zone，避免误用 provider 默认值。

### 4.2 凭证和备份

- 旧节点使用短期 SSH CA 用户（例如 `vault-migrate`），不要使用长期 root key 作为流水线凭证。
- XConnect 网络 secret、JWT role 和邀请 URI 只从 Vault 受控路径读取；邀请必须一次性、短 TTL。
- 迁移前取得 Vault Raft snapshot，完成 checksum、临时 Vault restore drill、age 加密、对象存储上传和 read-back 校验。
- unseal key、operator token、age 私钥保存在运维者受控位置，例如：
  - `/root/vault-migration/operator-token`
  - `/root/vault-migration/unseal-keys.json`

这些文件不上传 GitHub，不放入 Actions artifact，不通过命令行回显。

### 4.3 变更窗口和停止条件

变更前确认：

- KV path 数量和路径集合已在旧、新入口做只读对账；
- DNS 当前指向已知入口；
- 旧节点快照可读、可恢复演练通过；
- 新节点的 SSH host key 与声明 pin 匹配；
- TCP 8200/8201 在目标数据面双向可达；
- 有明确的 DNS 回滚入口和观察窗口；
- 任一 gate 失败时停止，不绕过 `stage_plan.py` 或 live-state 检查。

## 5. 统一流水线入口

所有阶段使用 `platform-ops-toolkit/.github/workflows/vault-server.yml`。每次 dispatch 只执行一类动作：

| 输入 | 用途 |
| --- | --- |
| `deploy_action=plan` | 只做 GCP IaC 计划，不执行节点阶段 |
| `deploy_action=apply` | 应用 GCP 资源声明；需要 `main` 和 `prod` 审批 |
| `deploy_action=none` | 只执行一个节点阶段或 DNS 验证前置 |
| `service_stage=<stage>` | 选择一个 `node-*`、`fresh-*` 或 `migrate-*` 阶段 |
| `dns_action=verify` | 只读检查 DNS 和 HTTPS endpoint |
| `dns_action=switch` | 切换到声明的新入口；需要 `confirm=SWITCH-VAULT-DNS` |
| `dns_action=rollback` | 切回旧入口；需要 `confirm=ROLLBACK-VAULT-DNS` |

`dns_action` 必须单独 dispatch，不能和节点阶段或 IaC apply 混用。live Vault 阶段必须使用 `main` 上的工作流和 reviewed GitOps ref。

## 6. 阶段 A：部署 GCP 节点

### A1. 只读计划

先检查声明和资源差异：

```bash
gh workflow run vault-server.yml \
  --repo ai-workspace-infra/platform-ops-toolkit \
  -f cloud_provider=gcp-cloud \
  -f deploy_action=plan \
  -f service_stage=none \
  -f dns_action=none \
  -f gitops_repo_ref=main \
  -f provider_manifest=resources/xworktech.com/shared/gcp/vault-shared.yaml
```

核对计划只创建或删除预期的 `vault-prod-*` 资源。缩容到一节点时，应看到只删除 `vault-prod-1/2` 及其地址、磁盘和关联资源。

### A2. 应用资源

```bash
gh workflow run vault-server.yml \
  --repo ai-workspace-infra/platform-ops-toolkit \
  -f cloud_provider=gcp-cloud \
  -f deploy_action=apply \
  -f service_stage=none \
  -f dns_action=none \
  -f gitops_repo_ref=main
```

apply 完成后先不做 DNS 切换，执行 `node-preflight` 和 `node-process-metrics`。确认 OS Login、临时 SSH、无 swap、sudo、磁盘、内核转发和监控均正常。

## 7. 阶段 B：建立 XConnect 数据面

### B1. 创建或重建网络

声明网络后执行 XConnect Zero Cloud and Network Bootstrap：

1. `deployment_profile=declared-network`
2. `network_environment=prod` 或 reviewed custom scope
3. 指定 GitOps manifest 和不可变 commit SHA
4. 先 `mode=dry-run`，检查 network ID、CIDR、Gateway ID、transport SNI/path 和 TTL
5. 再 `mode=apply`，由 `prod` Environment 审批

控制面只写入短期、一次性邀请的 Vault 路径；CI 不读取邀请内容。

### B2. Gateway 前端和 Gateway enrollment

按以下顺序执行 Vault workflow stage：

```text
vault-gateway-frontend
  -> xconnect-gateway
  -> xconnect-one
  -> xconnect-operator-invite（可选）
```

`vault-gateway-frontend` 在 Gateway 节点配置 Caddy TLS 443 和 `/xconnect`，但不直接开放 WireGuard UDP。

`xconnect-gateway`：

- 生成 Gateway 设备身份和 WireGuard key；
- 通过一次性邀请 enrollment；
- 确认 Gateway runtime、Xray、WireGuard、Caddy 均运行。

`xconnect-one`：

- 每个节点一次 enrollment；
- 新节点和旧节点都使用独立设备身份；
- 记录 overlay IP 到 GitOps topology 和 migration source；
- 不复用设备 key，不把 join URI 写进 shell history。

### B3. 数据面验收

在加入 Vault Raft 之前必须确认：

```bash
# 每个节点本地检查
systemctl is-active xconnect-gateway 2>/dev/null || systemctl is-active xconnect-one
ip addr show xconzero0 2>/dev/null || ip addr show xconone0

# overlay 连通性
ping -c 3 10.79.0.1

# Vault API 和 Raft 端口，只从允许的数据面执行
curl -fsS http://<overlay-or-private-address>:8200/v1/sys/health
nc -vz <peer-overlay-or-private-address> 8200
nc -vz <peer-overlay-or-private-address> 8201
```

验收标准：所有预期 peer 有最近 WireGuard handshake；overlay ping 成功；8200/8201 双向可达；公网扫描不能看到 8200/8201 或 UDP 51820。

## 8. 阶段 C：新集群 fresh 部署路径

fresh 路径只用于空白新集群，不能用于已经包含历史数据的迁移目标。

### C1. 安装 leader

```text
service_stage=fresh-leader
deploy_action=none
```

Playbook `vault-shared-leader` 只安装和配置 `vault-prod-0`。在受控运维终端手动执行：

```bash
export VAULT_ADDR=https://<leader-entrypoint>
vault operator init
vault operator unseal <one-share>
```

把剩余 share 和 root token 立即放入受控存储；不要粘贴到 Actions 日志。

### C2. 逐节点加入

每次只 dispatch 一次 `fresh-peers`：

1. Playbook 安装尚未加入的一个 peer；
2. 运维者在该节点使用批准的 unseal 材料 unseal；
3. 执行 `vault operator raft list-peers`，确认该节点是 voter；
4. 再 dispatch 下一次 `fresh-peers`。

三节点完成后执行：

```text
service_stage=vault-raft-verify
deploy_action=none
```

验收要求：所有节点 unsealed、Raft quorum healthy、leader/standby 角色正确、Raft 地址为私网或 overlay 地址。

## 9. 阶段 D：历史 Vault 迁移路径

迁移路径保留旧节点数据，不能执行 `fresh-leader` 或 `vault operator init`。

### D1. 迁移前预检

```text
service_stage=node-preflight
service_stage=node-process-metrics
service_stage=migrate-preflight
```

`migrate-preflight` 是只读报告，检查旧节点可达、Vault unsealed、存储类型、版本、磁盘备份目录和 overlay 地址。

### D2. 旧节点转换为单节点 Raft

确认旧节点已 enrollment 且 `legacy-overlay` 检查通过后：

```text
service_stage=migrate-convert
confirm=CONVERT-VAULT-TO-RAFT
deploy_action=none
```

Playbook `deploy_vault_legacy_migration.yml` 的 `vault-legacy-convert` 和 `vault-single-raft` tags 执行：

1. 备份旧 `vault_storage` 并计算 sha256；
2. 停止 Vault；
3. 将旧 PostgreSQL backend 数据迁移到本地 Raft 数据目录；
4. 写入单节点 Raft 配置；
5. 启用 host port guard，只允许 loopback/overlay 到达 8200/8201；
6. 启动 Vault。

转换后由运维者使用既有 key unseal，并检查 `vault.svc.plus` 仍可读。

如果转换失败，在确认 Raft 写入没有需要保留的变更后执行：

```text
service_stage=migrate-rollback
confirm=ROLLBACK-VAULT-TO-POSTGRESQL
```

该回滚只恢复 PostgreSQL-backed Vault；转换后新写入的 Raft 数据不会自动写回 PostgreSQL。

### D3. 备份和 restore drill

```text
service_stage=vault-snapshot
deploy_action=none
```

该阶段从 Vault API 获取 Raft snapshot，检查 `meta.json`、`state.bin`、`SHA256SUMS`，在 runner 的一次性 Vault 中执行 force-restore drill，再用 age 加密上传对象存储并 read-back 校验。

只有 snapshot、restore drill、加密上传和 read-back 全部成功，才允许新节点加入。

### D4. 新节点逐个加入

每个 peer 一次 dispatch：

```text
service_stage=migrate-join
deploy_action=none
```

阶段 gate 必须同时通过：

- 旧节点是 active Raft leader；
- 新节点没有 foreign cluster；
- `raft-overlay` 和 `overlay-raft-path` 成功；
- 新节点是声明中下一个尚未加入的 peer；
- snapshot-first 保护门通过。

Playbook 只负责加入配置，不初始化新集群。每个 peer 加入后：

1. 运维者使用既有 unseal 材料 unseal；
2. `vault operator raft list-peers` 确认 voter；
3. 检查复制状态和 leader 地址；
4. 再 dispatch 下一次 `migrate-join`。

### D5. Leader cutover

当所有新节点都是 unsealed voter 后：

```text
service_stage=migrate-cutover
confirm=MOVE-VAULT-LEADER
deploy_action=none
```

runner 使用 raft-operator 受限 token 请求旧节点 step-down，重试直到新节点成为 leader。此时旧节点仍可能以 standby 转发请求，所以 DNS 尚未切换。

### D6. DNS 切换和观察窗口

先执行只读验证：

```text
deploy_action=apply
service_stage=none
dns_action=verify
```

检查每个目标节点的 HTTPS、Vault health、cluster ID、版本、leader/standby 状态。确认矩阵全部通过后切换：

```text
deploy_action=apply
service_stage=none
dns_action=switch
confirm=SWITCH-VAULT-DNS
```

切换后记录 `spec.migration.observation.dns_switched_at`，观察窗口内持续检查：

- DNS resolver 结果；
- `sys/health` 和客户端读写；
- Raft peer/leader；
- XConnect handshake 和 8200/8201；
- 监控、审计日志和错误率。

### D7. 观察结束后移除旧 peer

观察窗口通过后：

```text
service_stage=migrate-remove
confirm=REMOVE-LEGACY-VAULT-PEER
deploy_action=none
```

该阶段只在 DNS 已切换、旧节点 standby、新节点全为 voter 且观察窗口满足时：

1. 通过 Vault API 移除旧 peer；
2. 停止并禁用旧节点 Vault；
3. 保留旧数据用于审计窗口，不立即删除；
4. 人工完成 rekey、旧 root token rotation/revoke 和 `vault_init.json` 清理。

## 10. 一节点与三节点扩缩容

### 10.1 一节点扩容到三节点

扩容顺序必须是“先声明、后资源、再入 Raft”：

1. GitOps 服务声明改为 `members: 3`，补充 `peers: [vault-prod-1, vault-prod-2]`；
2. shared GCP 资源声明增加两个节点、zone、host key、机器类型和公网 bootstrap 地址；
3. XConnect topology 增加两个 One 节点，确认 overlay IP 不冲突；
4. `deploy_action=plan`，确认只增加预期实例、磁盘、IP 和防火墙依赖；
5. `deploy_action=apply`；
6. `node-preflight`、`node-process-metrics`；
7. `xconnect-one` 逐节点 enrollment；
8. `migrate-join` 逐节点加入（已有数据集群）或 `fresh-peers` 逐节点加入（空白集群）；
9. 每个节点 unseal，确认 voter；
10. `vault-raft-verify` 和 `vault-service-verify`。

不得先创建 VM 再临时修改 Raft 地址；Raft `cluster_addr` 和 listener 必须从私网/overlay 声明生成。

### 10.2 三节点缩容到一节点

缩容前先判断是否真的要丢失 HA。推荐顺序：

1. 确认目标 leader 为 `vault-prod-0`；
2. 对 `vault-prod-1/2` 执行受控 `remove-peer`，确认不再是 voter；
3. 确认 `vault-prod-0` 单节点仍 initialized、unsealed、active；
4. GitOps 改为 `members: 1`、`peers: []`、只保留 `vault-prod-0`；
5. `deploy_action=plan`，确认只销毁 `prod-1/2` 的实例、地址、磁盘和关联资源；
6. `deploy_action=apply`；
7. 运行 CMDB resolver，确认只生成一个节点合同；
8. `dns_action=verify` 和 `vault-service-verify`。

缩容不应删除旧节点的独立 Vault。旧节点是否停机观察是独立运维动作，不由 GCP IaC 删除。

## 11. 回滚策略

回滚按变更阶段选择，不能把 DNS 回滚、Raft 回滚和 PostgreSQL 回滚混为一个动作。

| 失败点 | 回滚动作 | 关键限制 |
| --- | --- | --- |
| XConnect 未打通 | 停止后续 stage，修复 Gateway/One、handshake、8200/8201 | 不让节点加入 Raft |
| fresh leader 初始化失败 | 保留空白节点，修 Playbook/声明后重跑 | 不复用旧 snapshot |
| 旧节点转换失败 | `migrate-rollback` | Raft 转换后的新写入不回 PostgreSQL |
| snapshot/restore drill 失败 | 停止迁移，修备份链路 | 不执行 `migrate-join` |
| peer 加入后 unseal/复制失败 | 保留旧 leader，移除问题 peer 或修复节点 | 不执行 cutover |
| cutover 后 DNS 未切换 | 旧节点仍 standby/forwarding，先修复新 leader | 不移除旧 peer |
| DNS 切换后观察异常 | `dns_action=rollback` + `ROLLBACK-VAULT-DNS` | 先确认旧节点仍能安全提供服务 |
| 观察窗口通过后异常 | 不自动回滚，进入人工灾备评估 | 旧 peer 可能已移除 |
| 旧 peer 已移除后 | 使用最近 snapshot/灾备流程恢复 | 不能依赖旧节点自动重新加入 |

DNS 回滚示例：

```text
deploy_action=apply
service_stage=none
dns_action=rollback
confirm=ROLLBACK-VAULT-DNS
```

回滚完成后必须重新执行 DNS resolver、HTTPS health、Raft 状态和 KV 只读对账。不要让旧节点和新节点同时对外提供写流量。

## 12. 验收清单

### 12.1 CMDB/GCP

```bash
gcloud compute instances list \
  --project=open-platform-prod \
  --filter='name~^vault-prod-' \
  --format='table(name,zone,status,machineType,networkInterfaces[0].networkIP,networkInterfaces[0].accessConfigs[0].natIP)'

gcloud compute addresses list \
  --project=open-platform-prod \
  --filter='name~^vault-prod-' \
  --format='table(name,address,status,region)'
```

输出必须与 GitOps live shared 声明的 1 或 3 个节点完全一致。CMDB resolver 生成的 `NodeDeployment` 必须有正确的 provider、public/private address、host key、auth adapter 和 group。

### 12.2 Vault/Raft

```bash
export VAULT_ADDR=https://vault.svc.plus
vault status
vault operator raft list-peers
curl -fsS "$VAULT_ADDR/v1/sys/health"
```

核对：

- initialized/unsealed；
- 单节点时只有目标 leader；三节点时有一个 leader、两个 voter/standby；
- cluster address 不使用公网地址；
- 版本、cluster ID、审计配置和 KV mount 符合迁移前记录。

### 12.3 DNS/入口

```bash
for resolver in 1.1.1.1 8.8.8.8 9.9.9.9; do
  dig +short vault.svc.plus A @"$resolver"
done

curl -fsS https://vault.svc.plus/v1/sys/health
```

### 12.4 KV 对账

只读递归列出 KV v2 metadata path，比较旧、新入口的：

- mount 集合；
- 每个 mount 的版本；
- secret path 数量；
- 排序后的 path digest。

不要读取或打印 secret value。路径一致不代表每个 value 的业务语义都已验证，必要时再由业务 owner 执行受控 canary read。

## 13. 已完成实例的证据索引

本次迁移使用过的关键流水线：

| 操作 | Run ID |
| --- | ---: |
| 三节点扩容 apply | `36281561086` |
| 单节点 plan | `36287710987` |
| 单节点 apply | `36287784202` |
| 节点只读预检 | `36288700637` |
| DNS verify | `36288820528` |
| DNS switch | `36288982485`、`36289337733` |
| DNS rollback | `36289258912` |

本次最终状态的实施记录见：

- [`2026-09-27-gcp-vault-migration-implementation-record-zh.md`](../vault/2026-09-27-gcp-vault-migration-implementation-record-zh.md)
- [`Vault-Server-Migration.md`](Vault-Server-Migration.md)
- [`XConnect-Zero-Network-Bootstrap.md`](XConnect-Zero-Network-Bootstrap.md)

## 14. 故障处置原则

1. 先停止下一个阶段，不用强制参数跳过 gate。
2. 先看 live state：Vault health、Raft peers、WireGuard handshake、Caddy/Xray 日志和 DNS。
3. 确认当前唯一 active 写入口，再做修复或回滚。
4. 任何需要 root token、unseal share、operator token 的动作都在受控终端执行，不通过 GitHub Actions 输出。
5. 修复声明后重新 `plan`，确认差异只包含预期资源，再 `apply`。
6. 每次变更都留下 Git commit、Actions run ID、DNS 结果和 Vault/Raft 状态。
