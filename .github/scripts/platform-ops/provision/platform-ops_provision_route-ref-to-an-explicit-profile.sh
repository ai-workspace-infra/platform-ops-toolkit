#!/bin/bash
set -euo pipefail

# -----------------------------------------------------------------------------
# 域名基准集中定义, 各分支不要再各写各的字面量。
#
# 主机名由 TARGET_DOMAIN_BASE 拼接 (见 GitOps resources/*/*/*.yaml 里的
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
AKAMAI_UAT_PROJECT="svc.plus"
state_project="${STATE_PROJECT}"
REGISTRY_PATH="${GITHUB_WORKSPACE:-${PWD}}/config/iac_provider_registry.json"
ENVIRONMENT_DEFAULTS_PATH="${GITHUB_WORKSPACE:-${PWD}}/config/iac_environment_defaults.json"

registry_value() {
  local provider="$1"
  local field="$2"
  python3 - "${REGISTRY_PATH}" "${provider}" "${field}" <<'PY'
import json
import sys

registry_path, provider, field = sys.argv[1:]
registry = json.load(open(registry_path, encoding="utf-8"))
try:
    value = registry[provider][field]
except KeyError:
    raise SystemExit(2)
if value is None or value == "":
    raise SystemExit(2)
print(value)
PY
}

environment_default() {
  local environment="$1"
  local field="$2"
  python3 - "${ENVIRONMENT_DEFAULTS_PATH}" "${environment}" "${field}" <<'PY'
import json
import sys

defaults_path, environment, field = sys.argv[1:]
defaults = json.load(open(defaults_path, encoding="utf-8"))
try:
    value = defaults[environment][field]
except KeyError:
    raise SystemExit(2)
if value is None or value == "":
    raise SystemExit(2)
print(value)
PY
}

validate_provider() {
  local provider="$1"
  local provisioner
  provisioner="$(registry_value "${provider}" provisioner)" || {
    echo "::error::Unsupported cloud_provider '${provider}'. Add it to config/iac_provider_registry.json before selecting it." >&2
    return 1
  }
  if [[ "${provisioner}" != terraform ]]; then
    echo "::error::cloud_provider '${provider}' uses the '${provisioner}' adapter and cannot run the Terraform selfhost orchestrator." >&2
    return 1
  fi
}

provider_account() {
  local provider="$1"
  local account="${INPUT_CLOUD_ACCOUNT:-}"
  if [[ "${provider}" == "akamai-cloud" && -z "${account}" ]]; then
    account="${INPUT_AKAMAI_ACCOUNT:-}"
  fi
  if [[ -z "${account}" ]]; then
    account="$(environment_default "${deployment_env}" account)"
  fi
  printf '%s' "${account}"
}

default_provider_for_environment() {
  local environment="$1"
  printf '%s' "${CLOUD_PROVIDER_DEFAULT:-$(environment_default "${environment}" cloud_provider)}"
}

set_provider_metadata() {
  validate_provider "${cloud_provider}"
  provider_tree="$(registry_value "${cloud_provider}" terraform_tree)"
  provider_gitops_dir="$(registry_value "${cloud_provider}" gitops_provider)"
  provider_provisioner="$(registry_value "${cloud_provider}" provisioner)"
  provider_credential_mode="$(registry_value "${cloud_provider}" credential_mode)"
  account="$(provider_account "${cloud_provider}")"
  [[ -n "${account}" ]] || {
    echo "::error::No concrete account configured for cloud_provider '${cloud_provider}'. Set cloud_account or the provider-specific account input." >&2
    exit 1
  }
}

# Non-sensitive resource declarations live in the GitOps repository.  Keep the
# generated path absolute because this script runs from the toolkit checkout,
# while generate.py runs from the checked-out iac_modules directory.
resolve_gitops_resource_files() {
  local environment="$1"
  local provider="$2"
  local domains="$3"
  local gitops_root="${GITHUB_WORKSPACE:-${PWD}}/gitops/resources/svc.plus"
  local provider_dir
  provider_dir="$(registry_value "${provider}" gitops_provider)" || {
    echo "::error::Unsupported GitOps resource provider '${provider}'." >&2
    return 1
  }

  case "${domains}" in
    all)
      if [[ "${environment}" == "uat" && "${provider}" == "akamai-cloud" ]]; then
        printf '%s/%s/%s/web-saas.yaml,%s/%s/%s/open-platform.yaml,%s/%s/%s/ai-workspace.yaml,%s/%s/%s/xconnect.yaml' \
          "${gitops_root}" "${environment}" "${provider_dir}" \
          "${gitops_root}" "${environment}" "${provider_dir}" \
          "${gitops_root}" "${environment}" "${provider_dir}" \
          "${gitops_root}" "${environment}" "${provider_dir}"
      else
        printf '%s/%s/%s/all-in-one.yaml' "${gitops_root}" "${environment}" "${provider_dir}"
      fi
      ;;
    'web-saas + agent-proxy') printf '%s/%s/%s/web-saas.yaml,%s/%s/%s/agent-proxy.yaml' "${gitops_root}" "${environment}" "${provider_dir}" "${gitops_root}" "${environment}" "${provider_dir}" ;;
    *) printf '%s/%s/%s/%s.yaml' "${gitops_root}" "${environment}" "${provider_dir}" "${domains}" ;;
  esac
}
dns_mode=none
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
  target_domains="${INPUT_TARGET_DOMAINS:-web-saas}"
  requested_target_domains="${target_domains}"
  
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
  
  cloud_provider="${INPUT_CLOUD_PROVIDER:-$(default_provider_for_environment "${deployment_env}")}"
  set_provider_metadata
  state_project="${STATE_PROJECT}"
  uat_akamai_region_namespace=false
  akamai_matrix_mode=false
  akamai_matrix_action=none
  akamai_matrix_workspaces=""
  if [[ "${deployment_env}" == "uat" && "${cloud_provider}" == "akamai-cloud" ]]; then
    state_project="${AKAMAI_UAT_PROJECT}"
    case "${requested_target_domains}" in
      web-saas|open-platform|ai-workspace)
        terraform_namespace="${requested_target_domains}"
        ;;
      agent-proxy-jp|agent-proxy-us|agent-proxy-sg)
        terraform_namespace="${requested_target_domains}"
        uat_akamai_region_namespace=true
        target_domains=agent-proxy
        resource_files_full="$(resolve_gitops_resource_files "${deployment_env}" "${cloud_provider}" "${requested_target_domains}")"
        ;;
      all)
        # Aggregate UAT Akamai operations always fan out to six child
        # workflows, each with its own backend key and lockfile. The parent
        # must never render or operate a shared aggregate state. `deploy` is
        # a complete ordered child deployment; `plan`/`infra` remain the
        # Stage A Terraform-only fan-out modes.
        operation="${INPUT_OPERATION:-plan}"
        case "${operation}" in
          plan) akamai_matrix_action=plan ;;
          infra) akamai_matrix_action=apply ;;
          deploy) akamai_matrix_action=deploy ;;
          *)
            echo "::error::UAT Akamai target_domains=all supports only plan, infra, or deploy fan-out. Select one namespace for '${operation}'." >&2
            exit 1
            ;;
        esac
        if [[ "${INPUT_TARGET_DOMAIN_BASE:-${TARGET_DOMAIN_BASE_DEFAULT}}" != "onwalk.net" ]]; then
          echo "::error::UAT Akamai Stage A target_domains=all requires target_domain_base=onwalk.net." >&2
          exit 1
        fi
        akamai_matrix_mode=true
        akamai_matrix_workspaces="open-platform web-saas ai-workspace agent-proxy-jp agent-proxy-us agent-proxy-sg"
        terraform_namespace=akamai-uat-matrix
        rf=akamai-uat-matrix
        resource_file="${deployment_env}/akamai-matrix"
        resource_files_full=""
        terraform_workspace=""
        state_key=""
        ;;
      agent-proxy|'web-saas + agent-proxy'|infra-platform)
        echo "::error::UAT Akamai resources have six isolated Terraform namespaces; aggregate target '${requested_target_domains}' is disabled. Select one workload or one agent-proxy region, or use target_domains=all for Stage A plan/infra fan-out." >&2
        exit 1
        ;;
      *)
        echo "::error::Unsupported UAT Akamai target '${requested_target_domains}'. Select web-saas, open-platform, ai-workspace, agent-proxy-jp, agent-proxy-us, or agent-proxy-sg." >&2
        exit 1
        ;;
    esac
    if [[ "${akamai_matrix_mode}" != "true" ]]; then
      rf="${terraform_namespace}"
      resource_file="${deployment_env}/${terraform_namespace}"
      terraform_workspace="${deployment_env}-${state_project}-${cloud_provider}-${account}-${terraform_namespace}"
      state_key="terraform/${deployment_env}/${state_project}/${cloud_provider}/${account}/${terraform_namespace}/terraform.tfstate"
    fi
    if [[ "${operation:-${INPUT_OPERATION:-plan}}" == "destroy" && "${terraform_namespace}" == "open-platform" ]]; then
      echo "::error::The UAT open-platform Akamai namespace is permanent and cannot be destroyed by this workflow." >&2
      exit 1
    fi
  else
    terraform_namespace="${rf}"
    if [[ "${deployment_env}" == "uat" && "${requested_target_domains}" =~ ^agent-proxy-(jp|us|sg)$ ]]; then
      echo "::error::Regional Agent Proxy namespaces are available only with cloud_provider=akamai-cloud in UAT." >&2
      exit 1
    fi
  fi
  if [[ "${deployment_env}" != "uat" || "${cloud_provider}" != "akamai-cloud" ]]; then
    resource_file="${deployment_env}/${rf}"
    terraform_workspace="${deployment_env}-${state_project}-${cloud_provider}-${account}-${rf}"
    state_key="terraform/${deployment_env}/${state_project}/${cloud_provider}/${account}/${rf}/terraform.tfstate"
  fi
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
    migrate)
      run_infrastructure=false; run_application_deploy=false
      terraform_action=none; toolkit_action=migrate
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

  if [[ "${akamai_matrix_mode:-false}" == "true" ]]; then
    # The parent orchestrator only dispatches child workflows.  It must not
    # run Terraform against a synthetic matrix namespace or expose a shared
    # state key to downstream jobs.
    run_infrastructure=false
    run_application_deploy=false
    terraform_action=none
    toolkit_action=none
  fi

  if [[ "${operation}" == "migrate" || "${operation}" == "deploy+migrate" ]]; then
    case "${deployment_env}:${target_domains}" in
      uat:all|uat:web-saas|"uat:web-saas + agent-proxy")
        ;;
      *)
        echo "::error::Data migration is currently wired only for the UAT web-saas target. Use vault_env_path=uat and target_domains=all, web-saas, or web-saas + agent-proxy." >&2
        exit 1
        ;;
    esac
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

  if [ "${deployment_env}" = "prod" ]; then
    case "${GITHUB_REF:-}" in
      refs/tags/v*|refs/heads/release/v*) ;;
      *)
        echo "::error::prod accepts only refs/tags/v* or refs/heads/release/v*; select the workflow from an allowed release ref." >&2
        exit 1
        ;;
    esac
    if [ "${operation}" = "destroy" ]; then
      echo "::error::Production infrastructure is deletion-protected; destroy is not available through selfhost-orchestrator." >&2
      exit 1
    fi
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
  dns_mode="${INPUT_DNS_MODE:-none}"
  if [ "${operation}" = "destroy" ]; then
    # Destroy has no deployment or DNS side effects. Treat a stale UI value
    # such as uat-records/prod-cutover as inert instead of applying the
    # deploy-only DNS preflight to the Terraform destroy path.
    if [ "${dns_mode}" != "none" ]; then
      echo "::notice::Ignoring dns_mode=${dns_mode} for destroy; DNS updates are disabled." >&2
    fi
    dns_mode=none
    uat_dns_update=false
  else
    case "${dns_mode}" in
      none)
        uat_dns_update=false
        ;;
      uat-records)
        uat_dns_update=true
        ;;
      prod-cutover)
        if [ "${deployment_env}" != "prod" ]; then
          echo "::error::dns_mode=prod-cutover requires vault_env_path=prod." >&2
          exit 1
        fi
        uat_dns_update=false
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
    deployment_env=sit; resource_file=sit/all-in-one; cloud_provider="$(default_provider_for_environment sit)"
    set_provider_metadata
    terraform_workspace="sit-${STATE_PROJECT}-${cloud_provider}-${account}-all-in-one"
    resource_files_full="config/resources/sit/all-in-one.yaml"
    state_key="terraform/sit/${STATE_PROJECT}/${cloud_provider}/${account}/all-in-one/terraform.tfstate"; target_domains=all
    # PR 只做 terraform plan, 不 apply。四个 deploy job 都要求
    # terraform_action == 'apply', 所以 plan 会让它们全部 skip ——
    # PR 仍然校验 terraform 配置, 但不再创建真实 VPS。
    run_infrastructure=true; run_application_deploy=false
    terraform_action=plan; toolkit_action=none; infra_ref=main; playbooks_ref=main; gitops_ref=main; console_ref=main; toolkit_ref=main; offline_mode=off
    source_host="${SOURCE_HOST_DEFAULT}"; source_domain_base="${SOURCE_DOMAIN_BASE_DEFAULT}"; target_domain_base="${TARGET_DOMAIN_BASE_DEFAULT}"; env_suffix=-sit
  else
    case "${GITHUB_REF}" in
      refs/heads/main)
        deployment_env=uat; resource_file=uat/selfhost; cloud_provider="$(default_provider_for_environment uat)"
        set_provider_metadata
        state_project="${STATE_PROJECT}"; [[ "${cloud_provider}" == "akamai-cloud" ]] && state_project="${AKAMAI_UAT_PROJECT}"
        terraform_workspace="uat-${state_project}-${cloud_provider}-${account}-web-saas"
        resource_files_full="config/resources/uat/web-saas.yaml"
        state_key="terraform/uat/${state_project}/${cloud_provider}/${account}/web-saas/terraform.tfstate"; target_domains=web-saas
        # PR merge 后的 push 只做 IaC plan 校验，避免自动创建/变更真实资源。
        run_infrastructure=true; run_application_deploy=false
        terraform_action=plan; toolkit_action=none; infra_ref=main; playbooks_ref=main; gitops_ref=main; console_ref=main; toolkit_ref=main; offline_mode=off
    source_host="${SOURCE_HOST_DEFAULT}"; source_domain_base="${SOURCE_DOMAIN_BASE_DEFAULT}"; target_domain_base="${TARGET_DOMAIN_BASE_DEFAULT}"; env_suffix=-uat
        ;;
      refs/heads/release/v*|refs/tags/v*)
        deployment_env=prod; resource_file=prod/web-saas; cloud_provider="$(default_provider_for_environment prod)"
        set_provider_metadata
        terraform_workspace="prod-${STATE_PROJECT}-${cloud_provider}-${account}-web-saas"
        resource_files_full="config/resources/prod/web-saas.yaml"
        state_key="terraform/prod/${STATE_PROJECT}/${cloud_provider}/${account}/web-saas/terraform.tfstate"; target_domains=web-saas
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
        # A v* tag is a production plan-only trigger.  It still renders and
        # validates the production GitOps contract, whose public endpoints
        # live under svc.plus rather than the UAT default onwalk.net.
        source_host="${SOURCE_HOST_DEFAULT}"; source_domain_base="svc.plus"; target_domain_base="svc.plus"; env_suffix=""
        ;;
      refs/heads/release/*)
        deployment_env=uat; resource_file=uat/web-saas; cloud_provider="$(default_provider_for_environment uat)"
        set_provider_metadata
        state_project="${STATE_PROJECT}"; [[ "${cloud_provider}" == "akamai-cloud" ]] && state_project="${AKAMAI_UAT_PROJECT}"
        terraform_workspace="uat-${state_project}-${cloud_provider}-${account}-web-saas"
        resource_files_full="config/resources/uat/web-saas.yaml"
        state_key="terraform/uat/${state_project}/${cloud_provider}/${account}/web-saas/terraform.tfstate"; target_domains=web-saas
        run_infrastructure=true; run_application_deploy=false
        terraform_action=plan; toolkit_action=none; infra_ref=main; playbooks_ref=main; gitops_ref=main; console_ref=main; toolkit_ref=main; offline_mode=off
    source_host="${SOURCE_HOST_DEFAULT}"; source_domain_base="${SOURCE_DOMAIN_BASE_DEFAULT}"; target_domain_base="${TARGET_DOMAIN_BASE_DEFAULT}"; env_suffix=-uat
        ;;
      *)
        deployment_env=sit; resource_file=sit/all-in-one; cloud_provider="$(default_provider_for_environment sit)"
        set_provider_metadata
        terraform_workspace="sit-${STATE_PROJECT}-${cloud_provider}-${account}-all-in-one"
        resource_files_full="config/resources/sit/all-in-one.yaml"
        state_key="terraform/sit/${STATE_PROJECT}/${cloud_provider}/${account}/all-in-one/terraform.tfstate"; target_domains=all
        run_infrastructure=true; run_application_deploy=true
        terraform_action=apply; toolkit_action=deploy; infra_ref=main; playbooks_ref=main; gitops_ref=main; console_ref=main; toolkit_ref=main; offline_mode=off
    source_host="${SOURCE_HOST_DEFAULT}"; source_domain_base="${SOURCE_DOMAIN_BASE_DEFAULT}"; target_domain_base="${TARGET_DOMAIN_BASE_DEFAULT}"; env_suffix=-sit
        ;;
    esac
  fi
fi

# The route profile above still records the logical resource name for state and
# workspace compatibility. Resolve the physical declaration only after all
# event/ref branches have selected the final environment/provider.
if [[ "${GITHUB_EVENT_NAME}" != "workflow_dispatch" ||
  ("${uat_akamai_region_namespace:-false}" != "true" && "${akamai_matrix_mode:-false}" != "true") ]]; then
  resource_files_full="$(resolve_gitops_resource_files "${deployment_env}" "${cloud_provider}" "${target_domains}")"
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
  if [ "${deployment_env}" != "sit" ] && [ "${deployment_env}" != "uat" ]; then
    echo "::error::uat-records is only valid for sit or uat." >&2
    exit 1
  fi
  if [ -z "${target_domain_base}" ] || [ "${target_domain_base}" = "${source_domain_base}" ]; then
    echo "::error::uat_dns_update requires a non-empty target zone distinct from the source zone." >&2
    exit 1
  fi
  case "${target_domains}" in
    all|web-saas|"web-saas + agent-proxy") ;;
    agent-proxy)
      # The combined UAT path deploys Web SaaS serverlessly and provisions
      # only the Agent Proxy VPS. Its DNS stage publishes the agent-proxy A
      # record without requiring a selfhost web_saas host.
      if [[ "${INPUT_AGENT_CONTROLLER_URL:-}" != https://accounts-serverless-uat.onwalk.net ]]; then
        echo "::error::uat-records with target_domains=agent-proxy requires the serverless Accounts controller URL." >&2
        exit 1
      fi
      ;;
    *)
      echo "::error::uat_dns_update requires a target containing the web-saas domain." >&2
      exit 1
      ;;
  esac
  if [ "${run_infrastructure}" != "true" ] || [ "${run_application_deploy}" != "true" ] || [ "${terraform_action}" != "apply" ]; then
    echo "::error::uat_dns_update requires an apply plus application deployment so the run CMDB identifies the UAT web-saas host." >&2
    exit 1
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
  if [ "${operation:-}" = "destroy" ]; then
    deploy_tag=""
  else
    deploy_tag="${INPUT_DEPLOY_TAG:-${deploy_ref}}"
  fi
else
  case "${deployment_env}" in
    prod)
      case "${GITHUB_REF:-}" in
        refs/heads/release/v*) deploy_tag="${GITHUB_REF_NAME#release/}" ;;
        refs/tags/v*) deploy_tag="${GITHUB_REF_NAME}" ;;
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

include_external_agent_proxy="${INPUT_INCLUDE_EXTERNAL_AGENT_PROXY:-true}"
if [[ "${uat_akamai_region_namespace:-false}" == "true" ]]; then
  include_external_agent_proxy=false
fi
case "${include_external_agent_proxy}" in
  true|false) ;;
  *)
    echo "::error::include_external_agent_proxy must be true or false." >&2
    exit 1
    ;;
esac

# Agent Proxy normally registers against the Web SaaS Accounts service on the
# same Selfhost host. The combined UAT path overrides this with the already
# deployed Serverless Accounts endpoint, while keeping the default safe for
# standalone Selfhost runs.
agent_controller_url="${INPUT_AGENT_CONTROLLER_URL:-}"
if [[ -z "${agent_controller_url}" ]]; then
  agent_controller_url="https://accounts-selfhost-${deployment_env}.${target_domain_base}"
fi
if [[ ! "${agent_controller_url}" =~ ^https://[^/]+$ ]]; then
  echo "::error::agent_controller_url must be an HTTPS origin without a path." >&2
  exit 1
fi

# Billing follows the same runtime shape as the Accounts controller used by
# Agent Proxy. The combined UAT flow passes the serverless Accounts origin;
# standalone selfhost runs use the default selfhost origin. Keep this derived
# so callers never pin a serverless/selfhost Billing hostname themselves.
if [[ "${agent_controller_url}" == https://accounts-serverless-* ]]; then
  billing_service_base_url="https://billing-serverless-${deployment_env}.${target_domain_base}"
else
  billing_service_base_url="https://billing-selfhost-${deployment_env}.${target_domain_base}"
fi
if [[ ! "${billing_service_base_url}" =~ ^https://[^/]+$ ]]; then
  echo "::error::derived billing_service_base_url must be an HTTPS origin without a path." >&2
  exit 1
fi

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

terraform_namespace="${terraform_namespace:-${rf:-${target_domains}}}"
terraform_project="${state_project:-${STATE_PROJECT}}"
for key in deployment_env resource_file resource_files_full terraform_workspace state_key terraform_namespace terraform_project run_infrastructure run_application_deploy target_domains terraform_action toolkit_action deploy_ref infra_ref playbooks_ref gitops_ref console_ref toolkit_ref offline_mode cloud_provider provider_tree provider_gitops_dir provider_provisioner provider_credential_mode account source_host source_domain_base target_domain_base env_suffix dns_mode deploy_tag agent_controller_url billing_service_base_url include_external_agent_proxy akamai_matrix_mode akamai_matrix_action akamai_matrix_workspaces; do
  value="${!key:-}"
  echo "$key=$value" >> "$GITHUB_OUTPUT"
done

echo "vps_root=infra/iac_modules/terraform-hcl-standard/${provider_tree}" >> "$GITHUB_OUTPUT"
terraform_workdir="envs/platform-ops-toolkit"
if [[ "${deployment_env}" == "uat" && "${cloud_provider}" == "akamai-cloud" && "${akamai_matrix_mode:-false}" != "true" ]]; then
  # Akamai UAT has one Terraform root per namespace. The generator rejects
  # the historical shared directory because it would make six state locks
  # look like one workdir and can overwrite generated files between runs.
  terraform_workdir="${terraform_workdir}/${terraform_namespace}"
fi
echo "terraform_workdir=${terraform_workdir}" >> "$GITHUB_OUTPUT"
echo "env_dir=infra/iac_modules/terraform-hcl-standard/${provider_tree}/${terraform_workdir}" >> "$GITHUB_OUTPUT"

echo "vault_env_path=${deployment_env}" >> "$GITHUB_OUTPUT"
