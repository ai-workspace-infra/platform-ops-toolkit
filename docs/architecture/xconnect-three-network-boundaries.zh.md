# XConnect Zero 三网络边界

## 目标

XConnect Zero、Gateway、One 不再把安全管理网、UAT 和 PROD 混成一个网络。三张网络分别拥有独立的网络 ID、CIDR、Gateway 身份、Vault 记录和生命周期。

| 网络 | Gateway | 规划网段 | 生命周期 | 用途 |
| --- | --- | --- | --- | --- |
| `net_security_vault` | 受安全管理的 `vault-prod-0` | `10.79.0.0/24` | 常驻 | Vault 主节点、受控运维和安全管理通道 |
| `net_uat` | Ulighthost `tw-01` / `tw-xconnect.svc.plus` | 当前 UAT 声明的独立网段（现行为 `10.77.0.0/24`） | UAT | UAT `10.79.0.7`、Agent Proxy 以及 TW/PH existing 的零信任链路 |
| `net_prod_dedicated` | PROD 专用 Gateway 节点 | 规划 `10.81.0.0/24` | 常驻 | PROD Gateway/One 和生产节点，不复用 UAT 或 `vault-prod-0` |

`10.79.0.0/24` 只属于安全管理网络；`10.79.0.7` 是 UAT existing-selfhost 目标地址，不能因此把 UAT 节点或 UAT state 放入安全管理网络。PROD Gateway 节点由独立 IaC 声明创建，完成验收前不得替换 `vault-prod-0`。

## 仓库职责

- GitOps：网络 ID、CIDR、Gateway/One 角色、公开入口、生命周期、非敏感 Vault record path、节点归属。
- Vault：Zero service token、VLESS ID、Gateway/One SSH 私钥、sudo 密码、TLS 私钥、Observability 凭据。
- `platform-ops-toolkit`：按环境和网络 profile 调度 workflow、Vault JWT role、审批和只读验证；不得把密钥写入 dispatch input、Terraform state 或 CMDB。
- Ansible Playbook：安装和配置 Gateway/One、加入指定网络、配置 Caddy、监控探针和握手/私网连通性验收。
- `iac_modules`：仅管理声明为 Terraform 的云资源。PROD 专用 Gateway 节点需要独立 namespace/state；现有 `vault-prod-0` 和 UAT TW Gateway 不得被 Terraform 接管。

## 运行约束

1. UAT `target_domains=all` 先完成 Terraform 资源准备，再调用 GitOps 声明的 `net_uat` Gateway/One 门禁，成功后才对 `10.79.0.7`、TW/PH 和区域 Agent Proxy 执行 Playbook。
2. `net_security_vault` 只由安全管理/平台网络流程维护；业务发布不得调用其 cleanup 或修改其 Gateway。
3. PROD 使用独立的 `net_prod_dedicated` workflow 和 state；不能把 `prod/ulighthost-xconnect/tw-xconnect.svc.plus` 当作 PROD Gateway 的替代记录。
4. 每次运行摘要必须同时输出 `network_id`、CIDR、Gateway record path、One record path、Gateway/One 验收结果和回滚边界，但不得输出凭据值。

## 迁移顺序

先在 GitOps 合并三网络目录和 UAT matrix 的 `xconnect_network` 块，再在 Toolkit 合并按声明传递 `network_id`/record key 的调度器，最后由 `iac_modules` 增加 PROD 专用 Gateway 资源。未具备 PROD Gateway 的实际主机名、公钥和 Vault record 前，只能执行 `plan`，不能执行 PROD apply。
