#!/bin/bash
set -euo pipefail

# -----------------------------------------------------------------------------
# 域名基准集中定义, 各分支不要再各写各的字面量。
#
# 主机名由 TARGET_DOMAIN_BASE 拼接 (见 config/resources/*/*.yaml 里的
# console-uat.{{ TARGET_DOMAIN_BASE }}), 而 uat 的多条触发路径共用同一个
# terraform workspace 与 state。一旦取值不一致, 同一份 state 就会被要求
# 提供名字不同的资源, terraform 会销毁一台再建一台。
#
# SOURCE 是迁移的来源 (生产站点), TARGET 是要部署/发布到的站点。
# -----------------------------------------------------------------------------
SOURCE_HOST_DEFAULT="install.svc.plus"
SOURCE_DOMAIN_BASE_DEFAULT="svc.plus"
TARGET_DOMAIN_BASE_DEFAULT="onwalk.net"
STATE_PROJECT="platform-ops-toolkit"
dns_mode=none
confirm_dns_switch=false
uat_dns_update=false

validate_deploy_tag_policy() {
  local environment="$1"
  local tag="$2"

  # Infrastructure-only operations may intentionally omit an application tag.
  [[ -z "${tag}" ]] && return 0

  case "${environment}:${tag}" in
    prod:v*)
      ;;
    prod:*)
      echo "::error::PROD application deployments accept only v* deploy tags; daily and UAT snapshot tags are not production sources." >&2
      exit 1
      ;;
    uat:v*|sit:v*)
      echo "::error::v* release tags are PROD-only; UAT and SIT require daily-build-* or uat-daily-build-* tags." >&2
      exit 1
      ;;
  esac
}

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
  terraform_workspace="${deployment_env}-${cloud_provider}-${STATE_PROJECT}-${rf}"
  state_key="${deployment_env}/${cloud_provider}/${STATE_PROJECT}/${rf}.tfstate"
  # UI 使用单一 operation。下游 job 只消费解析后的执行意图，避免在
  # workflow 中重复拼接相互矛盾的开关条件。
  operation="${INPUT_OPERATION:-plan}"
  deploy_ref="${INPUT_DEPLOY_REF:-${INPUT_DEPLOY_TAG:-}}"

  # Destroy is infrastructure-only and must not be blocked by a stale
  # application tag left in a reused workflow-dispatch form.
  if [ "${operation}" != "destroy" ]; then
    validate_deploy_tag_policy "${deployment_env}" "${INPUT_DEPLOY_TAG:-${INPUT_DEPLOY_REF:-}}"
  fi

  case "${operation}" in
    plan)
      run_infrastructure=true; run_application_deploy=false
      terraform_action=plan; toolkit_action=none
      ;;
    infra)
      run_infrastructure=true; run_application_deploy=false
      terraform_action=apply; toolkit_action=deploy
      ;;
    deploy)
      run_infrastructure=true; run_application_deploy=true
      terraform_action=apply; toolkit_action=deploy
      ;;
    deploy+migrate)
      run_infrastructure=true; run_application_deploy=true
      terraform_action=apply; toolkit_action=deploy+migrate
      ;;
    destroy)
      run_infrastructure=true; run_application_deploy=false
      terraform_action=destroy; toolkit_action=none
      ;;
    *)
      echo "::error::Unsupported operation '${operation}'." >&2
      exit 1
      ;;
  esac

  case "${deployment_env}" in
    sit) env_suffix=-sit ;;
    uat) env_suffix=-uat ;;
    prod) env_suffix="" ;;
    *)
      echo "Unsupported workflow_dispatch vault_env_path: ${deployment_env}" >&2
      exit 1
      ;;
  esac

  if [ "${deployment_env}" = "prod" ]; then
    case "${GITHUB_REF:-}" in
      refs/tags/v*|refs/heads/release/v*) ;;
      *)
        echo "::error::prod accepts only refs/tags/v* or refs/heads/release/v*; select the workflow from an allowed release ref." >&2
        exit 1
        ;;
    esac
  fi
  
  source_ref="${INPUT_SOURCE_REF:-}"
  infra_ref="${source_ref:-main}"
  playbooks_ref="${source_ref:-main}"
  gitops_ref="${source_ref:-main}"
  console_ref="${source_ref:-${deploy_ref:-main}}"
  toolkit_ref="${source_ref:-main}"
  offline_mode="${INPUT_OFFLINE_MODE}"
  source_host="${INPUT_SOURCE_HOST}"
  source_domain_base="${INPUT_SOURCE_DOMAIN_BASE}"
  target_domain_base="${INPUT_TARGET_DOMAIN_BASE}"
  cloud_provider="${INPUT_CLOUD_PROVIDER:-vultr-vps}"
  dns_mode="${INPUT_DNS_MODE:-none}"
  if [ "${operation}" = "destroy" ]; then
    # Destroy has no deployment or DNS side effects. Treat a stale UI value
    # such as uat-records/prod-cutover as inert instead of applying the
    # deploy-only DNS preflight to the Terraform destroy path.
    if [ "${dns_mode}" != "none" ] || [ "${INPUT_CONFIRM_DNS_SWITCH:-false}" = "true" ]; then
      echo "::notice::Ignoring dns_mode=${dns_mode} and confirm_dns_switch for destroy; DNS updates are disabled." >&2
    fi
    dns_mode=none
    confirm_dns_switch=false
    uat_dns_update=false
  else
    case "${dns_mode}" in
      none)
        confirm_dns_switch=false; uat_dns_update=false
        ;;
      uat-records)
        confirm_dns_switch=false; uat_dns_update=true
        ;;
      prod-cutover)
        if [ "${INPUT_CONFIRM_DNS_SWITCH:-false}" != "true" ]; then
          echo "::error::dns_mode=prod-cutover requires confirm_dns_switch=true." >&2
          exit 1
        fi
        confirm_dns_switch=true; uat_dns_update=false
        ;;
      *)
        echo "::error::Unsupported dns_mode '${dns_mode}'." >&2
        exit 1
        ;;
    esac
  fi
else
  GITHUB_EVENT_NAME="${GITHUB_EVENT_NAME:-}"
  if [ "${GITHUB_EVENT_NAME}" = "pull_request" ]; then
    deployment_env=sit; resource_file=sit/all-in-one; terraform_workspace=sit-vultr-vps-platform-ops-toolkit-all-in-one
    resource_files_full="config/resources/sit/all-in-one.yaml"
    state_key=sit/vultr-vps/platform-ops-toolkit/all-in-one.tfstate; target_domains=all
    # PR 只做 terraform plan, 不 apply。四个 deploy job 都要求
    # terraform_action == 'apply', 所以 plan 会让它们全部 skip ——
    # PR 仍然校验 terraform 配置, 但不再创建真实 VPS。
    run_infrastructure=true; run_application_deploy=false
    terraform_action=plan; toolkit_action=none; infra_ref=main; playbooks_ref=main; gitops_ref=main; console_ref=main; toolkit_ref=main; offline_mode=off
    cloud_provider="vultr-vps"
    source_host="${SOURCE_HOST_DEFAULT}"; source_domain_base="${SOURCE_DOMAIN_BASE_DEFAULT}"; target_domain_base="${TARGET_DOMAIN_BASE_DEFAULT}"; env_suffix=-sit; confirm_dns_switch=false
  else
    case "${GITHUB_REF}" in
      refs/heads/main)
        deployment_env=uat; resource_file=uat/web-saas; terraform_workspace=uat-vultr-vps-platform-ops-toolkit-web-saas
        resource_files_full="config/resources/uat/web-saas.yaml"
        state_key=uat/vultr-vps/platform-ops-toolkit/web-saas.tfstate; target_domains=web-saas
        # PR merge 后的 push 只做 IaC plan 校验，避免自动创建/变更真实资源。
        run_infrastructure=true; run_application_deploy=false
        terraform_action=plan; toolkit_action=none; infra_ref=main; playbooks_ref=main; gitops_ref=main; console_ref=main; toolkit_ref=main; offline_mode=off
        cloud_provider="vultr-vps"
        source_host="${SOURCE_HOST_DEFAULT}"; source_domain_base="${SOURCE_DOMAIN_BASE_DEFAULT}"; target_domain_base="${TARGET_DOMAIN_BASE_DEFAULT}"; env_suffix=-uat; confirm_dns_switch=false
        ;;
      refs/heads/release/v*|refs/tags/v*)
        deployment_env=prod; resource_file=prod/web-saas; terraform_workspace=prod-vultr-vps-platform-ops-toolkit-web-saas
        resource_files_full="config/resources/prod/web-saas.yaml"
        state_key=prod/vultr-vps/platform-ops-toolkit/web-saas.tfstate; target_domains=web-saas
        # 与 main/release push 一样只做 plan 校验, 不自动 apply/部署 —— 这才是
        # 文件顶部注释说的设计: "pull_request 和 branch/tag push 都只跑
        # provision 阶段, 只有 workflow_dispatch 能真正 apply/deploy"。这里此前
        # 是这条设计唯一的例外(run_application_deploy=true、terraform_action=
        # apply), 2026-08-04 因此被撞了两次: 一次是跨仓快照脚本意外用
        # v2026.8.4 打了 tag, 直接把这个仓库拉进一次真实 prod apply+deploy
        # (只因 gitops/compose/web-saas/.env.prod 缺失才没跑完); 另一次是有意
        # 打一个真正的发布快照点, 但同样不希望它在没人盯着的情况下自动落地。
        # 打 release tag 现在只做 plan 校验, 真正的 prod 部署必须走
        # workflow_dispatch 显式触发, 由人选择 action=deploy 并确认输入。
        run_infrastructure=true; run_application_deploy=false
        terraform_action=plan; toolkit_action=none; infra_ref=main; playbooks_ref=main; gitops_ref=main; console_ref=main; toolkit_ref=main; offline_mode=off
        cloud_provider="vultr-vps"
        source_host="${SOURCE_HOST_DEFAULT}"; source_domain_base="${SOURCE_DOMAIN_BASE_DEFAULT}"; target_domain_base="${TARGET_DOMAIN_BASE_DEFAULT}"; env_suffix=""; confirm_dns_switch=false
        ;;
      refs/heads/release/*)
        deployment_env=uat; resource_file=uat/web-saas; terraform_workspace=uat-vultr-vps-platform-ops-toolkit-web-saas
        resource_files_full="config/resources/uat/web-saas.yaml"
        state_key=uat/vultr-vps/platform-ops-toolkit/web-saas.tfstate; target_domains=web-saas
        run_infrastructure=true; run_application_deploy=false
        terraform_action=plan; toolkit_action=none; infra_ref=main; playbooks_ref=main; gitops_ref=main; console_ref=main; toolkit_ref=main; offline_mode=off
        cloud_provider="vultr-vps"
        source_host="${SOURCE_HOST_DEFAULT}"; source_domain_base="${SOURCE_DOMAIN_BASE_DEFAULT}"; target_domain_base="${TARGET_DOMAIN_BASE_DEFAULT}"; env_suffix=-uat; confirm_dns_switch=false
        ;;
      *)
        deployment_env=sit; resource_file=sit/all-in-one; terraform_workspace=sit-vultr-vps-platform-ops-toolkit-all-in-one
        resource_files_full="config/resources/sit/all-in-one.yaml"
        state_key=sit/vultr-vps/platform-ops-toolkit/all-in-one.tfstate; target_domains=all
        run_infrastructure=true; run_application_deploy=true
        terraform_action=apply; toolkit_action=deploy; infra_ref=main; playbooks_ref=main; gitops_ref=main; console_ref=main; toolkit_ref=main; offline_mode=off
        cloud_provider="vultr-vps"
        source_host="${SOURCE_HOST_DEFAULT}"; source_domain_base="${SOURCE_DOMAIN_BASE_DEFAULT}"; target_domain_base="${TARGET_DOMAIN_BASE_DEFAULT}"; env_suffix=-sit; confirm_dns_switch=false
        ;;
    esac
  fi
fi

uat_dns_update="${uat_dns_update:-false}"
case "${uat_dns_update}" in
  true|false) ;;
  *)
    echo "::error::uat_dns_update must be true or false." >&2
    exit 1
    ;;
esac

if [ "${uat_dns_update}" = "true" ]; then
  if [ "${deployment_env}" != "uat" ]; then
    echo "::error::uat_dns_update is UAT-only; vault_env_path must be uat." >&2
    exit 1
  fi
  if [ -z "${target_domain_base}" ] || [ "${target_domain_base}" = "${source_domain_base}" ]; then
    echo "::error::uat_dns_update requires a non-empty target zone distinct from the source zone." >&2
    exit 1
  fi
  case "${target_domains}" in
    all|web-saas|"web-saas + agent-proxy") ;;
    *)
      echo "::error::uat_dns_update requires a target containing the web-saas domain." >&2
      exit 1
      ;;
  esac
  if [ "${run_infrastructure}" != "true" ] || [ "${run_application_deploy}" != "true" ] || [ "${terraform_action}" != "apply" ]; then
    echo "::error::uat_dns_update requires an apply plus application deployment so the run CMDB identifies the UAT web-saas host." >&2
    exit 1
  fi
  confirm_dns_switch=false
elif [ "${deployment_env}" = "uat" ] && [ "${confirm_dns_switch:-false}" = "true" ]; then
  echo "::error::UAT DNS updates must use uat_dns_update=true; the generic confirm_dns_switch path is disabled for UAT." >&2
  exit 1
fi

# 所有触发路径都必须给这两个开关显式赋值 —— 空串会让下游 == 'true' 比较
# 静默为假, 表现成"没被请求", 与"结构上跑不起来"无法区分。
: "${run_infrastructure:?route: run_infrastructure was never assigned on this trigger path}"
: "${run_application_deploy:?route: run_application_deploy was never assigned on this trigger path}"

# 应用交付必须使用明确的不可变镜像 tag。
# 现已将 UI 统一收敛为 deploy_tag 作为主入口，
# 此处直接读取即可，后续会强制拦截 main/latest 等动态 ref，确保镜像不可变性。
if [ "${GITHUB_EVENT_NAME:-}" = "workflow_dispatch" ]; then
  if [ "${operation:-}" = "destroy" ]; then
    deploy_tag=""
  else
    deploy_tag="${INPUT_DEPLOY_TAG:-${deploy_ref}}"
  fi
else
  case "${deployment_env}" in
    prod)
      case "${GITHUB_REF:-}" in
        refs/heads/release/v*|refs/tags/v*) deploy_tag="${GITHUB_REF_NAME}" ;;
        *)
          echo "::error::prod deploy_tag must come from refs/tags/v* or refs/heads/release/v* on non-dispatch triggers." >&2
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
validate_deploy_tag_policy "${deployment_env}" "${deploy_tag}"

# docker tag 里 '/' 非法, 所以 release/v1.4 的镜像实际叫 release-v1.4
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

for key in deployment_env resource_file resource_files_full terraform_workspace state_key run_infrastructure run_application_deploy target_domains terraform_action toolkit_action deploy_ref infra_ref playbooks_ref gitops_ref console_ref toolkit_ref offline_mode cloud_provider source_host source_domain_base target_domain_base env_suffix dns_mode deploy_tag; do
  value="${!key:-}"
  echo "$key=$value" >> "$GITHUB_OUTPUT"
done

echo "vault_env_path=${deployment_env}" >> "$GITHUB_OUTPUT"
