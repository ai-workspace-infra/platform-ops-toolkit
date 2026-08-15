#!/bin/bash
set -euo pipefail

terraform workspace select -or-create "${ENV_STEPS_ROUTE_OUTPUTS_TERRAFORM_WORKSPACE}"

ACTION="${ENV_STEPS_ROUTE_OUTPUTS_TERRAFORM_ACTION}"
case "${ACTION}" in
  plan)
    terraform plan -input=false
    ;;
  apply)
    plan_file="${RUNNER_TEMP:-/tmp}/platform-ops-${ENV_STEPS_ROUTE_OUTPUTS_TERRAFORM_WORKSPACE}.tfplan"
    plan_json="${plan_file}.json"
    terraform plan -input=false -out="${plan_file}"
    terraform show -json "${plan_file}" > "${plan_json}"

    downgrade_count="$(jq '
      def rank:
        if . == "vc2-1c-1gb" then 1
        elif . == "vc2-1c-2gb" then 2
        elif . == "vc2-2c-4gb" then 3
        elif . == "vc2-4c-8gb" then 4
        else 0
        end;
      [ .resource_changes[]?
        | select(.type == "vultr_instance")
        | select(.change.actions == ["update"])
        | .change as $change
        | ($change.before.plan | rank) as $before
        | ($change.after.plan | rank) as $after
        | select($before > $after and $after > 0)
      ] | length
    ' "${plan_json}")"

    if [[ "${downgrade_count}" != 0 ]]; then
      echo "::error::Vultr does not support in-place VPS downgrades. Re-run platform-ops with action=resize so the guarded replacement workflow can snapshot, validate, adopt state, and deploy the new instance." >&2
      exit 1
    fi

    terraform apply -input=false -auto-approve "${plan_file}"
    ;;
  destroy)
    # 空 workspace 上的 destroy 会输出 "0 destroyed" 并成功退出。断言这不是
    # 选错 profile 造成的假绿 —— 机器还在跑、还在计费, 流水线却是绿的。
    "${GITHUB_WORKSPACE:-.}/.github/scripts/platform-ops/provision/platform-ops_provision_assert-destroy-scope.sh"
    terraform destroy -auto-approve -input=false
    ;;
  *)
    echo "::error::unsupported terraform action: ${ACTION}" >&2
    exit 1
    ;;
esac
