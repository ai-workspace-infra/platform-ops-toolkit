# Toolkit ownership scanner 行为合同（2026-10-05）

此批只修改 scanner、冻结登记与非变更测试，不切 caller、不删 executor、不访问 Vault/云资源/主机。基线 Toolkit `ec7bc9b1`。后续迁移仍需 owner → caller → 验证 → cleanup；scanner 的 `owner` 字段是评审提示，不是归属授权或 UAT 证据。

## 修正的行为

- 捕获已调用的 shell SSH/Provider 数组与常见 scalar wrapper、环境前缀下的 AWS 调用、本地主机 systemctl/sysctl/WireGuard/package 操作。
- 捕获 curl 的 variable request method、参数数组、隐式 data/upload 写入。未知 HTTP 写入使用 `http_execution_review`，不把任意 HTTP POST 自动归 IaC。
- 有限证明 Vault `/v1/`、OIDC 与 Accounts internal bootstrap URL/别名的控制面请求，不以 header 或同文件出现 Vault 为整体豁免。alias 被重赋为未知 endpoint 时不放行。
- 仅识别精确的 `gcloud run services/revisions describe`、`docker buildx imagetools inspect` 与 `aws sts get-caller-identity` 只读门禁；同文件其它写入仍拒绝新增。去掉 `/serverless/` 一律 Playbooks 的目录规则。
- 对每个登记 legacy 的实际文件字节独立检查 SHA；不能通过改命令拼写/移除 marker 绕过冻结。文件真正删除仍允许通过 scanner，但它不能证明 cleanup 已获验收，评审必须另外查证。

## 重新核对的冻结登记

原 scanner 的 8 个候选：3 个是控制面误报，5 个仍是执行/混合债务；本轮补登记 10 个旧漏检，共 **15 个**。数量增加只表示检测覆盖变化，不能称新增执行或迁移倒退，也不能称已完成 cleanup。

| 分类 | 路径/行为证据 | 当前处置 |
| --- | --- | --- |
| 控制面误报（3） | agent-proxy/database credential initializer 只有 Vault KV 编排；`verify_cloud_run_image_digest.sh` 是 Cloud Run describe + OCI inspect 发布门禁 | 从 execution debt 登记移出，原脚本字节未改；不是删除、迁移或运行验收 |
| 原真实债务（5） | SMTP Secret Manager；existing-One deploy；lab deploy/enroll/run | 保持原 SHA 冻结，SMTP provider owner 提示修正为 IaC；混合脚本还须拆分，不能整体按标签搬运 |
| Caddy/DNS 漏检（4） | Caddy 使用 ssh_command 数组；UAT/SIT/gateway DNS 使用动态 curl 写入 | 新增冻结；Caddy #570/#1273 与 gateway owner #393 不等于全部 caller/UAT/cleanup 完成，旧副本保留 |
| XConnect 漏检（6） | desktop、gateway、lease、prepare.py、remote-client-observation、remote-gateway-observation | 真实 SSH/host probe/installation 或 AWS provider/state 操作；新登记原始 SHA，未切调用 |

`lease.sh` 的 S3 状态操作属于 IaC，过期 cleanup dispatch 属于 Toolkit；`prepare.py` 的 Provider read/资源事实仍需 IaC 合同。host+provider+unknown HTTP 复合 markers 必须逐行为审查，不以一个推断 owner 掩盖混合边界。

## 验证和限制

测试覆盖动态 host/provider、未知 HTTP owner review、Vault header 不能豁免外国 endpoint、同文件 Vault + 其它写入、只读门禁 + 写入、目录无关、marker-removal SHA 绕过、真实 repository 候选/控制面回归。fixtures 只写临时 Git 仓和读取源码，不执行来源脚本。

这是有限静态 review aid，不是完整 shell/Python parser、安全认证或 caller graph。动态 eval、复杂 alias/data flow、跨文件 executor 与新 CLI 仍需人工核对；不宣称这 15 项是全部债务。尤其 `.github/scripts` 的薄 wrapper 可以调用其它目录的旧 executor，不能据 scanner 无 marker 宣称职责已收敛。
