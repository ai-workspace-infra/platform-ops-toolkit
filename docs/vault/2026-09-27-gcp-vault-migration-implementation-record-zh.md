# GCP Vault 迁移与资源对账实施记录

日期：2026-09-27
环境：`shared` / GCP `open-platform-prod` / `asia-east1`
服务：`vault.svc.plus`

## 1. 最终状态

| 项目 | 结果 |
| --- | --- |
| GCP Vault 节点 | 仅 `vault-prod-0`，`RUNNING` |
| GCP 私网地址 | `10.81.0.4` |
| GCP 公网地址 | `35.221.167.104` |
| Vault 状态 | initialized、unsealed、active leader |
| Raft | 单节点，`vault-prod-0` 为 voter/leader |
| Vault 版本 | 1.21.4 |
| DNS | `vault.svc.plus` 仅返回 `35.221.167.104` |
| 旧节点 | `vault-2` 保留为独立 Vault server，未加入 GCP Raft |

旧节点当前为 Vault 1.21.3、独立单节点 Raft leader。它没有被删除，也没有修改其业务数据。

## 2. 声明与 CMDB 对账

GitOps `main` 当前声明：

- `spec.storage.members: 1`
- `spec.storage.leader: vault-prod-0`
- `spec.storage.peers: []`
- `spec.migration.raft_network: private`
- `resources/xworktech.com/shared/gcp/vault-shared.yaml` 的 live shared 资源声明仅包含 `vault-prod-0`
- `resources/xworktech.com/prod/gcp/open-platform-prod.yaml` 仍保留 `vault-prod-0/1/2` 三节点扩容模板；它不是本次 shared 工作区的实际资源清单
- 该 prod provider 文件的全局默认网络为 `open-platform-prod`、机型为 `e2-standard-2`；本次 shared 资源声明明确覆盖为 `vault-shared`、`e2-highcpu-2`，实际 GCP 资源与 shared 覆盖值一致。
- GCP VPC `vault-shared`，子网 `10.81.0.0/20`
- 机器类型 `e2-highcpu-2`，Debian 12，50 GB `pd-balanced`

使用主干声明和实时 GCP 实例/防火墙输出重新生成 NodeDeployment CMDB 合同，结果为 1 个节点：

```text
vault-prod-0
provider: gcp
public: 35.221.167.104
private: 10.81.0.4
ssh adapter: gcp-oslogin-ephemeral
groups: vault_shared_nodes, xconnect_gateway, vault_shared_peers
```

声明中的 ED25519 主机密钥与 `ssh-keyscan 35.221.167.104` 实际值匹配。

## 3. GCP 实际资源核对

| 资源 | 实际结果 |
| --- | --- |
| Compute instance | 实际仅 `vault-prod-0`，`asia-east1-a`，`RUNNING`；prod provider 文件中的 `vault-prod-1/2` 只是扩容模板 |
| Static address | `vault-prod-0-public-ip` → `35.221.167.104`，`IN_USE` |
| Boot disk | `vault-prod-0`，50 GB，`pd-balanced`，`READY` |
| Runtime service account | `vault-prod-0-runtime@open-platform-prod.iam.gserviceaccount.com`，未禁用 |
| Network | `vault-shared`，regional routing |
| Subnet | `vault-shared-subnet`，`10.81.0.0/20`，Private Google Access 开启 |
| Cloud NAT | 未配置，符合声明 `enable_cloud_nat: false` |
| HTTPS firewall | `0.0.0.0/0` → TCP/443 |
| Raft firewall | `10.81.0.0/20` → TCP/8200、8201 |
| SSH firewall | `35.79.83.48/32` → TCP/22 |

`vault-prod-1`、`vault-prod-2` 的实例、地址、磁盘和运行时服务账号均已由 IaC 缩容清理。

## 4. Vault 与网络核验

`vault-prod-0`：

- systemd Vault：`active`
- storage：Raft
- sealed：`false`
- Raft peers：仅 `vault-prod-0 10.81.0.4:8201 leader true`
- `net.ipv4.ip_forward=1`
- `rp_filter=0`
- XConnect Gateway 地址：`10.79.0.1`

旧节点 `vault-2`：

- 独立 Raft peer：仅 `vault-2 46.250.251.132:8201 leader true`
- sealed：`false`
- 未加入 GCP Raft

## 5. 流水线与变更记录

### 扩容与缩容

- 三节点扩容 apply：`36281561086`，成功；三节点均成为 Raft voter，Autopilot healthy
- 单节点 plan：`36287710987`，`0 add / 0 change / 10 destroy`
- 单节点 apply：`36287784202`，成功；最终只保留 `vault-prod-0`
- CMDB/节点只读预检：`36288700637`，成功

### DNS 切换、回滚、再次切换

- DNS verify：`36288820528`，成功
- DNS switch：`36288982485`，成功
- DNS rollback：`36289258912`，成功
- 最终 DNS switch：`36289337733`，成功
- 1.1.1.1、8.8.8.8、9.9.9.9 均最终返回 `35.221.167.104`

### 合并的 PR

- GitOps 单节点资源声明：[#316](https://github.com/ai-workspace-infra/gitops/pull/316)
- GitOps 私网 Raft 单节点声明：[#317](https://github.com/ai-workspace-infra/gitops/pull/317)
- 独立旧 Vault DNS 回滚校验：[#1030](https://github.com/ai-workspace-infra/platform-ops-toolkit/pull/1030)
- 独立旧 Vault leader 回滚兼容：[#1031](https://github.com/ai-workspace-infra/platform-ops-toolkit/pull/1031)

## 6. 实施路径

1. 通过 SSH 与 WireGuard over VLESS 建立旧节点和 GCP 节点的数据面。
2. 直接 SSH 初始化/加入三节点 Raft，并确认三节点 voter 与 Autopilot 健康。
3. 安全移除 `vault-prod-1/2` 的 Raft 成员，提交 GitOps 单节点声明。
4. IaC apply 清理 `prod-1/2` 的实例、地址、磁盘和服务账号。
5. 使用旧 Vault Raft snapshot 恢复 `vault-prod-0` 单节点数据，并使用既有 unseal 材料恢复服务。
6. 先执行 DNS switch，再执行 rollback 验证旧节点，最后再次 switch 到 `vault-prod-0`。

## 7. 已知事项与后续动作

- `resources/xworktech.com/prod/gcp/open-platform-prod.yaml` 与 `vpn-overlay/shared/xconnect-vault-shared.yaml` 仍保留三节点扩容模板，而 shared live 声明和 CMDB 只有 `vault-prod-0`；扩容前必须先恢复三节点资源声明并核对该拓扑。
- 扩容或切换 provider 前还需显式确认网络、子网和机型覆盖，避免误用 prod provider 的旧默认值。
- 旧节点和 GCP 节点因同一 Raft snapshot 拥有相同 `cluster_id`。两套独立 server 不得同时接受写流量；DNS 与人工切换必须保持单一 active 写入口。
- 迁移流水线的 snapshot-first 保护门仍要求声明 off-site backup 配置；当前没有该 backup secret，因此本次数据恢复使用了已审计的直接 SSH snapshot/restore 路径。后续应补齐 backup 声明后再启用完整 `migrate-join` 自动路径。
