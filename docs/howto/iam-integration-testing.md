# iam.svc.plus 自动测试与手动验收

适用范围：GCP、AWS、Linode、Vultr、UCloud Global、Grafana。
OIDC 优先；只有目标账号对应用途不支持 OIDC 才选择 SAML。
workforce 控制台登录、workload API 身份、application 登录分别验收。
控制台 SSO 成功不能证明 API 联邦可用。

## 1. 自动测试

所有用例使用假凭据、临时目录或 mock provider；不连接真实 Vault，不执行
Terraform apply，不启动 Docker，不更改 IdP。Terraform init 需要下载 provider，
因此首次运行需要网络；缓存安装完成后测试本身不需要云服务。

依赖：Bash、Python 3.12+、jq、Ruby（含 minitest）、Terraform 1.16.0（与 CI 一致）。
Grafana 测试通过真实 Ansible template 模块渲染，依赖见
`playbooks/tests/requirements-iam.txt`。当前 CI 固定 Terraform 1.16.0。

在包含四个项目的工作区根目录执行：

```bash
python3 -m venv /tmp/iam-test-venv
/tmp/iam-test-venv/bin/python -m pip install -r playbooks/tests/requirements-iam.txt
export PATH="/tmp/iam-test-venv/bin:$PATH"
bash platform-ops-toolkit/scripts/tests/run_iam_tests.sh \
  "$PWD/platform-ops-toolkit" "$PWD/gitops" "$PWD/playbooks" "$PWD/iac_modules"
```

四个参数可分别指向独立 PR worktree。聚合脚本遇到任何失败立即非零退出；
Terraform 在临时副本中执行，退出后清理。不得将包含真实 payload 的目录作为
测试临时目录。CI 的每个仓库独立执行自己拥有的测试，不读取其他仓库的 main。

| 用例 | 项目/入口 | 自动断言 |
|---|---|---|
| KV-01 | toolkit `scripts/tests/test_identity_bootstrap.py` | 六个 wrapper 正确路由；检查零写入 |
| KV-02 | 同上 | 首次 CAS=0；更新 CAS=读取版本；保留已有字段 |
| KV-03 | 同上 | 403、超时、TLS、认证失败时零写入 |
| KV-04 | 同上 | 模拟版本冲突失败；一次写入尝试，无重试或覆盖 |
| KV-05 | 同上 | JSON 类型/语法、必填字段、0600、路径穿越、未知组合拒绝 |
| KV-06 | 同上 | 完整记录 check 成功；缺失/空记录失败；零写入 |
| KV-07 | 同上 | 假 secret 不进入日志/argv；临时目录0700、文件0600且清理 |
| DECL-01..04 | gitops `tests/test_iam_integrations.rb` | 正常声明通过；22 个负面场景失败，覆盖协议、路径、环境、敏感字段、回调 |
| AWS-01..02 | iac `modules/oidc_federation/tests/federation.tftest.hcl` | 精确 aud/sub、唯一联邦 principal；7 个非法输入 plan 失败 |
| GF-01..03 | playbooks `tests/test_grafana_oidc_runtime.py` | 开关、完整配置、6 个错误配置、端点、PKCE、严格角色映射、0600、日志脱敏 |
| E2E-01（路径合同） | toolkit `scripts/tests/test_identity_cross_repo.py --gitops-root PATH` | 读取真实声明的全部 IAM ref；bootstrap 能按对应 provider/purpose 检查假 KV，且不写入 |

本地已有 provider 镜像时，可设置 `IAM_TEST_PLUGIN_DIR` 为 Terraform provider
镜像根目录，让聚合脚本使用 `init -plugin-dir`，避免重复下载。

以上不证明真实 CAS 并发、Vault ACL、IdP 签名校验、云端角色权限、用户禁用
传播及登录成功。它们必须按下面步骤验收。root 文件所有者也需要在部署目标检查，
本地渲染测试使用当前用户，仅检查权限。

## 2. 验收前准备

1. 使用 UAT 专用账号和 IdP 测试应用；记录目标 cloud account/project/company ID。
2. 记录四个仓库 commit、IdP 应用 ID、协议、精确回调、audience、角色/组映射。
3. 准备授权用户、无权限用户、不同 subject 的 workload；Grafana 用户先预建。
4. 确认应急管理员在独立浏览器能登录；备份配置版本，写好恢复步骤。
5. 所有真实敏感数据只保存在 Vault；需临时输入时使用受限 tmpfs/临时文件，
   `umask 077`，用完删除。关闭 shell trace；不截图 token、secret、assertion。
6. 能力确认失败记为 BLOCKED，不能自动改为 API token 或声称 OIDC/SAML 已支持。

## 3. Vault KV v2 实测（P0）

隔离路径形如 `kv/iam/uat/aws/acceptance-test/workload`。使用仅能访问该路径的
测试 policy；不修改正常账号的 KV。payload 须是假的但字段齐全的 JSON，0600。

```bash
# PAYLOAD_FILE 由操作者提供，不在仓库创建真实 payload。
bash scripts/cloud/bootstrap/aws/bootstrap_aws_iam_kv.sh \
  --env uat --account acceptance-test --purpose workload --apply --payload-file "$PAYLOAD_FILE"
bash scripts/cloud/bootstrap/aws/bootstrap_aws_iam_kv.sh \
  --env uat --account acceptance-test --purpose workload --check
# 只查看元数据，不显示数据内容。
vault kv metadata get -mount=kv -format=json iam/uat/aws/acceptance-test/workload \
  | jq '{current_version: .data.current_version}'
```

| 用例 | 操作 | 预期/证据 |
|---|---|---|
| VAULT-01 / P0 | 首次写入，再更改一个假字段写入；受控校验进程只输出比较结果 | 版本增加，未覆盖字段保留；记录版本与 PASS |
| VAULT-02 / P0 | 用无读取权限 token 执行 apply | 非零退出；管理员只读检查版本不变 |
| VAULT-03 / P0 | 用能读不能写 token 执行 apply；尝试跨环境 check | 写入/越权读取失败；版本不变 |
| VAULT-04 / P0 | 两个客户端读到同一版本后，同步用该版本 CAS 写不同假值 | 恰好一个成功，另一个冲突；最终只包含成功值 |
| VAULT-05 / P0 | 将完整假 payload 写到目标记录后执行 check | 必填字段齐全；Vault ref 与声明一致 |

VAULT-04 必须通过屏障保证双方读到同一版本；单纯并行启动两个 bootstrap
可能串行成功，不能据此证明并发保护。验收结束由路径负责人清理隔离记录和测试 ACL，
并记录清理结果；不把生产 Vault 清理混入脚本。

## 4. OIDC/JWT 共用验收（P0）

使用专用应用和真实 relying party。每次用干净浏览器会话或新一次 token 请求。
错误 token 必须由测试 issuer/application 合法生成；直接编辑 JWT 会变成签名
错误，不能单独证明 audience/expiry 校验。

| 编号 | 操作 | 预期 |
|---|---|---|
| OIDC-01 | 授权用户执行正常 Authorization Code 登录；检查脱敏认证记录 | 登录成功，issuer、用户和目标应用正确 |
| OIDC-02 | 使用另一个测试 issuer 签发的 token | 目标 relying party 拒绝 |
| OIDC-03 | 使用正确 issuer、错误 audience 的有效签名 token | 拒绝，不能只依赖应用端预检查 |
| OIDC-04 | 使用已过期的正确签名 token；单独测试未来 nbf | 拒绝；服务时钟同步、允许偏差已记录 |
| OIDC-05 | 修改签名或使用未信任签名 key | 拒绝 |
| OIDC-06 | 浏览器授权流程修改 state；用测试代理替换 nonce 对应 ID token | 拒绝且不建立会话 |
| OIDC-07 | 请求未注册回调；重用已兑换授权 code | IdP 拒绝回调，token 端点拒绝 code 重放 |
| OIDC-08 | 使用错误 PKCE verifier 兑换 code | 拒绝；正常 verifier 成功 |

nonce/state/code/PKCE 用于浏览器流程；workload JWT 验收不套用这些条件。
记录错误码、脱敏 request ID 和时间，不记录 token 或完整授权 URL。

## 5. 各接入的实际验收（P0）

| 编号 | 接入 | 操作与成功条件 | 拒绝用例 |
|---|---|---|---|
| GCP-WF | GCP workforce OIDC | 授权用户通过测试 workforce provider 登录指定项目；principal 与组映射正确；允许的只读操作成功 | 无权限用户、跨项目操作和未授权管理操作失败 |
| GCP-WL | GCP workload OIDC | 指定 subject/audience 换取短期凭据；service account 对应声明；记录到期时间 | 错误 subject/audience 无法换取；目标外资源操作失败 |
| AWS-WF | AWS workforce SAML | 目标 Identity Center identity source 确认 SAML；测试用户取得指定 permission set | 无分配用户、未授权账号、未授予操作失败 |
| AWS-WL | AWS workload OIDC | 正确 JWT 调用 AssumeRoleWithWebIdentity；role ARN 正确、凭据短期 | 错误 subject/audience/issuer 失败；最小权限之外 API 被拒绝 |
| LINODE-WF | Linode SAML | 目标 Cloud Manager 账号确认能力；NameID 对应正确用户；只读控制台操作成功 | 未匹配用户和越权操作失败 |
| VULTR-WF | Vultr OIDC | 确认目标账号 OIDC 可用和真实 redirect URI；授权用户回调并登录 | 无权限用户、未注册回调失败；不将控制台身份用作 API 凭据 |
| UCLOUD-WF | UCloud Global SAML | company ID、ACS、entity ID、NameID 与子用户映射正确；指定权限操作成功 | 错公司/用户映射及越权操作失败 |
| GRAFANA-APP | Grafana OIDC | 预建 Viewer/Editor/Admin 分别登录；只获得对应角色；外部 URL 为 HTTPS | 未预建用户、缺角色用户失败；Viewer 写操作被拒绝 |
| API-FALLBACK | Linode/Vultr/UCloud workload | 确认声明引用与已有 Vault API 凭据一致；最小权限只读请求成功 | 跨账号/越权请求失败；此项记为 API 凭据验收，不记为 OIDC |

AWS 可用下面命令仅输出会话到期与身份，避免显示短期凭据；JWT_FILE 为0600
的运行时临时文件，测试完成即清理：

```bash
aws sts assume-role-with-web-identity \
  --role-arn "$TEST_ROLE_ARN" --role-session-name iam-acceptance \
  --web-identity-token "file://$JWT_FILE" \
  --query '[Credentials.Expiration,AssumedRoleUser.Arn]' --output json
```

SAML 接入分别在专用测试应用执行：合法已签名 assertion 成功；未签名/改签名、
错误 Audience、错误 Recipient/ACS、过期 assertion、重复 assertion 被拒绝。
由测试 IdP/测试工具逐一生成正确签名的负面样本；不在生产账号上重放 assertion。
记录 SP 错误与脱敏事件，不导出 assertion 到验收文档。

Grafana 目标机另外检查：`grafana.env` 的 root 所有者、0600；Compose 没有明文
secret；部署日志和 `--diff` 无 secret；实际 ZITADEL claims 匹配配置的角色表达式。
不要使用默认 admin/admin 作为应急管理员凭据。

## 6. 撤销、轮换与回滚

| 编号 | 优先级 | 操作 | 通过条件 |
|---|---|---|---|
| LIFE-01 | P1 | 禁用测试用户、撤销组/角色；重新登录和申请新凭据 | 新访问按预期失败；已有会话最大存活时间明确并实测 |
| LIFE-02 | P1 | 轮换 OIDC signing key，记录 JWKS cache 窗口 | 新 key 成功；被撤销旧 key 在约定窗口后拒绝 |
| LIFE-03 | P1 | 轮换 client secret/SAML 证书 | 新凭据成功；移除旧凭据后旧凭据失败；期间无锁死 |
| ROLLBACK-01 | P0 | 测试配置恢复到启用前版本；独立应急管理员登录 | 能恢复登录；IAM 权限未扩大；正常用户行为恢复 |
| AUDIT-01 | P0 | 检查成功、拒绝、权限变更事件 | 可关联用户、目标账号、时间、request ID；无 secret/token |

## 7. 验收记录模板

复制以下表格，每个用例一行。状态仅允许 PASS/FAIL/BLOCKED/NOT_RUN；
BLOCKED 和 NOT_RUN 不能计为通过。

| 用例 | 四仓库版本/环境 | 账号或测试应用 | 预期 | 实际/状态 | 脱敏证据与时间 | 清理/负责人 |
|---|---|---|---|---|---|---|
| GRAFANA-APP | 待填/UAT | 待填 | 三角色正确、缺角色拒绝 | NOT_RUN | 待填 | 待填 |

每个接入的所有适用 P0（包括共用认证、Vault、权限、回滚与审计）PASS 后才能启用。
P1 通过后再扩大用户范围。例外必须记录明确的风险、负责人和截止日期。
