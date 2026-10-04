# Host runner composite 第一批去重范围

依赖 UAT 业务晋级门槛 PR #1239；本 PR 只整理 runner-side CMDB 下载、Vault OIDC deploy-key 注入和 runner setup。没有迁移 host 脚本，没有更改 Playbooks roles，没有扩大生产操作范围。

接口位于 `.github/actions/prepare-host-runner/action.yml`。调用者显式传入 Vault 地址、环境 role、KV v2 key path 和 CMDB host；DB Init 可继续读取 ROOT_BOOTSTRAP_PASSWORD、导出 Vault token、安装 Ansible 和断言 inventory。私钥仅在内部交给已有 setup-deployment-runner；不增加私钥 action output。

第一批替换 capture_web_saas_baseline、accept_web_saas_upgrade、initialize_web_saas_databases 三个 job 的重复链路。这三个 job 原本就从 github.sha checkout Toolkit，保证新 local action 来自 workflow commit。其他 observe/deploy jobs 仍可能 checkout 旧 toolkit_ref；不直接引用新 action，以免对旧 release dispatch 引入缺失 action 的运行错误。扩展它们时应单独明确工作流代码 checkout 与业务构件 checkout 的关系。

下载始终来自当前 run 的 platform-ops-toolkit-cmdb，路径 cmdb。Vault audience、role/path、secret 名、required-secret failure、DB Init exportToken 和 runner flags 保留。执行顺序依然是 download → Vault → setup → PostgreSQL readiness → DB Init；门槛 job 的 if/needs/部署 tag 没有改变。

验证包含新 action 的安全/来源反例、已有 setup-deployment-runner 行为测试、Web SaaS 接线契约和 workflow 引用检查。此批去重不代表 134 个脚本的全量归属审计已完成；runner-side glue 保留 Toolkit，真正的主机阶段代码应在 Playbooks 自己的 PR 内处理并先完成依赖交付。
