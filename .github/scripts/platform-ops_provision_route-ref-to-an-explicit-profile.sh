#!/bin/bash
set -euo pipefail

# -----------------------------------------------------------------------------
# 域名基准集中定义, 各分支不要再各写各的字面量。
#
# 主机名由 TARGET_DOMAIN_BASE 拼接 (见 config/resources/*/*.yaml 里的
# console-nat.{{ TARGET_DOMAIN_BASE }}), 而 uat 的多条触发路径共用同一个
# terraform workspace 与 state。一旦取值不一致, 同一份 state 就会被要求
# 提供名字不同的资源, terraform 会销毁一台再建一台。
#
# SOURCE 是迁移的来源 (生产站点), TARGET 是要部署/发布到的站点。
# -----------------------------------------------------------------------------
SOURCE_HOST_DEFAULT="install.svc.plus"
SOURCE_DOMAIN_BASE_DEFAULT="svc.plus"
TARGET_DOMAIN_BASE_DEFAULT="onwalk.net"
# Defaults are intentionally safe: no branch deployment reads a host
# variable. Terraform creates the host and its CMDB is the only deploy
# inventory for that run.
if [ "${GITHUB_EVENT_NAME}" = "workflow_dispatch" ]; then
  deployment_env="${INPUT_VAULT_ENV_PATH:-uat}"
  target_domains="${INPUT_TARGET_DOMAINS:-all}"
  
  if [ "${deployment_env}" = "sit" ]; then
    rf="all-in-one"
    resource_files_full="config/resources/${deployment_env}/all-in-one.yaml"
  elif [ "${target_domains}" = "all" ]; then
    rf="web-saas"
    resource_files_full="config/resources/${deployment_env}/web-saas.yaml"
  elif [ "${target_domains}" = "web-saas + agent-proxy" ]; then
    rf="web-saas-agent-proxy"
    resource_files_full="config/resources/${deployment_env}/web-saas.yaml,config/resources/${deployment_env}/agent-proxy.yaml"
  else
    rf="${target_domains}"
    resource_files_full="config/resources/${deployment_env}/${target_domains}.yaml"
  fi
  
  cloud_provider="${INPUT_CLOUD_PROVIDER:-vultr-vps}"
  resource_file="${deployment_env}/${rf}"
  terraform_workspace="${rf}-${deployment_env}-${cloud_provider}"
  state_key="platform-ops-toolkit/${deployment_env}/${cloud_provider}/${rf}.tfstate"
  # 执行边界拆成两段独立开关, 不再由一个参数同时代表"建基础设施"和"部署业务":
  #   run_infrastructure -> Terraform render/init/apply|destroy + CMDB/matrix
  #   run_application_deploy  -> Bootstrap Node + 四个业务域部署
  # 两者默认都是 false, 手动触发必须显式选择要做什么。
  run_infrastructure="${INPUT_RUN_INFRASTRUCTURE:-false}"
  run_application_deploy="${INPUT_RUN_APPLICATION_DEPLOY:-false}"
  deploy_ref="${INPUT_DEPLOY_REF:-${INPUT_DEPLOY_TAG:-}}"
  user_action="${INPUT_ACTION}"

  if [ "$user_action" = "destroy" ]; then
    # Destroy is an infrastructure-only action and must not depend on the
    # optional run_infrastructure checkbox.
    run_infrastructure=true
    run_application_deploy=false
  fi

  # 一键整套初始化: 申请 IaC 资源 -> 部署业务应用 -> 发布 DNS。
  # 它不是第三种模式, 只是把上面两个开关和 DNS 发布一起打开, 这样"整套拉起
  # 一个 sit/uat/prod 副本"是一次勾选, 而不是三次且必须记住顺序。
  # 显式覆盖而非 || 兜底: 勾了它就是要整套, 不该被同时传入的 false 悄悄削弱。
  if [ "${INPUT_RUN_FULL_STACK:-false}" = "true" ]; then
    run_infrastructure=true
    run_application_deploy=true
    confirm_dns_switch_override=true
  fi

  # 非法组合必须显式失败, 不能静默跳过: 部署所用的 inventory (CMDB) 是在
  # provision 阶段生成的, 跳过基础设施阶段就没有 inventory 可用。
  if [ "${run_infrastructure}" != "true" ] && [ "${run_application_deploy}" = "true" ]; then
    echo "::error::run_application_deploy=true requires run_infrastructure=true because the current deployment inventory is generated during provisioning." >&2
    exit 1
  fi

  case "${deployment_env}" in
    sit) env_suffix=-sit ;;
    uat) env_suffix=-uat ;;
    prod) env_suffix="" ;;
    *)
      echo "Unsupported workflow_dispatch vault_env_path: ${deployment_env}" >&2
      exit 1
      ;;
  esac
  
  if [ "$user_action" = "destroy" ]; then
    terraform_action="destroy"
    toolkit_action="none"
  else
    terraform_action="apply"
    toolkit_action="$user_action"
  fi
  
  infra_ref="${INPUT_INFRA_REF:-main}"
  playbooks_ref="${INPUT_PLAYBOOKS_REF:-main}"
  gitops_ref="${INPUT_GITOPS_REF:-main}"
  console_ref="${INPUT_CONSOLE_REF:-${deploy_ref:-main}}"
  toolkit_ref="${INPUT_TOOLKIT_REF:-main}"
  offline_mode="${INPUT_OFFLINE_MODE}"
  source_host="${INPUT_SOURCE_HOST}"
  source_domain_base="${INPUT_SOURCE_DOMAIN_BASE}"
  target_domain_base="${INPUT_TARGET_DOMAIN_BASE}"
  cloud_provider="${INPUT_CLOUD_PROVIDER:-vultr-vps}"
  confirm_dns_switch="${confirm_dns_switch_override:-${INPUT_CONFIRM_DNS_SWITCH}}"
else
  GITHUB_EVENT_NAME="${GITHUB_EVENT_NAME:-}"
  if [ "${GITHUB_EVENT_NAME}" = "pull_request" ]; then
    deployment_env=sit; resource_file=sit/all-in-one; terraform_workspace=all-in-one-sit-vultr-vps
    resource_files_full="config/resources/sit/all-in-one.yaml"
    state_key=platform-ops-toolkit/sit/vultr-vps/all-in-one.tfstate; target_domains=all
    # PR 只做 terraform plan, 不 apply。四个 deploy job 都要求
    # terraform_action == 'apply', 所以 plan 会让它们全部 skip ——
    # PR 仍然校验 terraform 配置, 但不再创建真实 VPS。
    run_infrastructure=true; run_application_deploy=false
    terraform_action=plan; toolkit_action=none; infra_ref=main; playbooks_ref=main; gitops_ref=main; console_ref=main; toolkit_ref=main; offline_mode=off
    cloud_provider="vultr-vps"
    source_host="${SOURCE_HOST_DEFAULT}"; source_domain_base="${SOURCE_DOMAIN_BASE_DEFAULT}"; target_domain_base="${TARGET_DOMAIN_BASE_DEFAULT}"; env_suffix=-sit; confirm_dns_switch=false
  else
    case "${GITHUB_REF}" in
      refs/heads/main|refs/heads/release/*)
        deployment_env=uat; resource_file=uat/web-saas; terraform_workspace=web-saas-uat-vultr-vps
        resource_files_full="config/resources/uat/web-saas.yaml"
        state_key=platform-ops-toolkit/uat/vultr-vps/web-saas.tfstate; target_domains=web-saas
        # PR merge 后的 push 只做 IaC plan 校验，避免自动创建/变更真实资源。
        run_infrastructure=true; run_application_deploy=false
        terraform_action=plan; toolkit_action=none; infra_ref=main; playbooks_ref=main; gitops_ref=main; console_ref=main; toolkit_ref=main; offline_mode=off
        cloud_provider="vultr-vps"
        source_host="${SOURCE_HOST_DEFAULT}"; source_domain_base="${SOURCE_DOMAIN_BASE_DEFAULT}"; target_domain_base="${TARGET_DOMAIN_BASE_DEFAULT}"; env_suffix=-uat; confirm_dns_switch=false
        ;;
      refs/tags/v*)
        deployment_env=prod; resource_file=prod/web-saas; terraform_workspace=web-saas-prod-vultr-vps
        resource_files_full="config/resources/prod/web-saas.yaml"
        state_key=platform-ops-toolkit/prod/vultr-vps/web-saas.tfstate; target_domains=web-saas
        run_infrastructure=true; run_application_deploy=true
        terraform_action=apply; toolkit_action=deploy; infra_ref=main; playbooks_ref=main; gitops_ref=main; console_ref=main; toolkit_ref=main; offline_mode=off
        cloud_provider="vultr-vps"
        source_host="${SOURCE_HOST_DEFAULT}"; source_domain_base="${SOURCE_DOMAIN_BASE_DEFAULT}"; target_domain_base="${TARGET_DOMAIN_BASE_DEFAULT}"; env_suffix=""; confirm_dns_switch=false
        ;;
      *)
        deployment_env=sit; resource_file=sit/all-in-one; terraform_workspace=all-in-one-sit-vultr-vps
        resource_files_full="config/resources/sit/all-in-one.yaml"
        state_key=platform-ops-toolkit/sit/vultr-vps/all-in-one.tfstate; target_domains=all
        run_infrastructure=true; run_application_deploy=true
        terraform_action=apply; toolkit_action=deploy; infra_ref=main; playbooks_ref=main; gitops_ref=main; console_ref=main; toolkit_ref=main; offline_mode=off
        cloud_provider="vultr-vps"
        source_host="${SOURCE_HOST_DEFAULT}"; source_domain_base="${SOURCE_DOMAIN_BASE_DEFAULT}"; target_domain_base="${TARGET_DOMAIN_BASE_DEFAULT}"; env_suffix=-sit; confirm_dns_switch=false
        ;;
    esac
  fi
fi
# 所有触发路径都必须给这两个开关显式赋值 —— 空串会让下游 == 'true' 比较
# 静默为假, 表现成"没被请求", 与"结构上跑不起来"无法区分。
: "${run_infrastructure:?route: run_infrastructure was never assigned on this trigger path}"
: "${run_application_deploy:?route: run_application_deploy was never assigned on this trigger path}"

# 应用交付必须使用明确的不可变镜像 tag。
# 现已将 UI 统一收敛为 deploy_tag 作为主入口，
# 此处直接读取即可，后续会强制拦截 main/latest 等动态 ref，确保镜像不可变性。
if [ "${GITHUB_EVENT_NAME:-}" = "workflow_dispatch" ]; then
  deploy_tag="${INPUT_DEPLOY_TAG:-}"
else
  case "${deployment_env}" in
    prod)
      case "${GITHUB_REF:-}" in
        refs/tags/v*) deploy_tag="${GITHUB_REF_NAME}" ;;
        *)
          echo "::error::prod deploy_tag must come from a v* tag on non-dispatch triggers." >&2
          exit 1
          ;;
      esac
      ;;
    uat)
      deploy_tag=""
      ;;
    sit)
      deploy_tag=""
      ;;
    *)
      echo "::error::cannot derive deploy_tag for unknown deployment_env '${deployment_env}'" >&2
      exit 1
      ;;
  esac
fi
# An empty deploy_tag is valid for infrastructure-only dispatches (including
# destroy). Keep the guard for missing assignment without requiring a value.
: "${deploy_tag+x}"

# docker tag 里 '/' 非法, 所以 release/1.4 的镜像实际叫 release-1.4
# (docker/metadata-action 自己就这么转)。这里不转的话, CD 会去 pull 一个
# 从来没有被推送过的 tag。规则见 docs/domains/IMAGE-TAG-CONTRACT.md。
deploy_tag="${deploy_tag//\//-}"

if [ "${run_application_deploy}" = "true" ]; then
  case "${deploy_tag}" in
    ""|latest|main)
      echo "::error::application deployment requires an explicit immutable deploy_tag (for example, daily-build-2026.07.30-r1). Set workflow_dispatch input deploy_tag; deploy_ref is only a source checkout ref, and main/latest are not valid image versions." >&2
      exit 1
      ;;
  esac
fi

for key in deployment_env resource_file resource_files_full terraform_workspace state_key run_infrastructure run_application_deploy target_domains terraform_action toolkit_action deploy_ref infra_ref playbooks_ref gitops_ref console_ref toolkit_ref offline_mode cloud_provider source_host source_domain_base target_domain_base env_suffix confirm_dns_switch deploy_tag; do
  value="${!key:-}"
  echo "$key=$value" >> "$GITHUB_OUTPUT"
done

echo "vault_env_path=${deployment_env}" >> "$GITHUB_OUTPUT"
