#!/usr/bin/env bash
set -euo pipefail

# -----------------------------------------------------------------------------
# destroy 之前核对: 这个 workspace 的 state 是否真的覆盖了本次 profile 声明的
# 那些实例。
#
# 为什么需要: terraform destroy 只销毁 state 里有的东西。选错 profile 时它会
# 打在一个空 workspace 上, 输出 "Destroy complete! Resources: 0 destroyed." 并
# 以成功退出 —— 机器还在跑、还在计费, 流水线却是绿的。2026-08-06 就是这样:
# 一次 destroy 落在 ...-web-saas, 真实资源在 ...-web-saas-agent-proxy, 没人
# 发现, 直到几小时后 plan 因为孤儿 state 崩掉才暴露出来。
#
# 判据是"云上有没有本 profile 声明的实例", 不是"state 空不空":
#   - state 有资源                     -> 正常 destroy。
#   - state 空, 云上也没有对应 label   -> 真的已经销毁干净了, 放行(重复
#                                          destroy 必须保持幂等)。
#   - state 空, 云上却有对应 label     -> 假绿, 硬失败并报出实例 ID。
# label 取自 render 阶段就落盘的 hosts_manifest.json, 不依赖 apply 后的 cmdb。
# -----------------------------------------------------------------------------

: "${ENV_STEPS_ROUTE_OUTPUTS_TERRAFORM_WORKSPACE:?terraform workspace is required}"
: "${ENV_STEPS_ROUTE_OUTPUTS_STATE_KEY:?terraform state key is required}"
: "${VULTR_API_KEY:?VULTR_API_KEY is required}"
: "${HOSTS_MANIFEST:=hosts_manifest.json}"

state_json="$(terraform show -json 2>/dev/null || echo '{}')"
managed_instances="$(
  jq -r '
    def resources: .. | objects | select(has("resources")) | .resources[];
    [ (.values.root_module? // empty) | resources ]
    | map(select(.mode == "managed" and .type == "vultr_instance"))
    | length
  ' <<<"${state_json}"
)"

if [[ "${managed_instances}" -gt 0 ]]; then
  echo "Destroy scope: workspace ${ENV_STEPS_ROUTE_OUTPUTS_TERRAFORM_WORKSPACE} manages ${managed_instances} instance(s); proceeding."
  exit 0
fi

[[ -f "${HOSTS_MANIFEST}" ]] || {
  echo "::error::${HOSTS_MANIFEST} is missing; run generate.py render before asserting destroy scope." >&2
  exit 1
}

mapfile -t expected_labels < <(jq -r '.hosts[]?.label | select(. != "")' "${HOSTS_MANIFEST}")
if [[ "${#expected_labels[@]}" -eq 0 ]]; then
  echo "Destroy scope: this profile declares no hosts; nothing to destroy."
  exit 0
fi

instances="$(curl -fsS --retry 3 --retry-connrefused \
  -H "Authorization: Bearer ${VULTR_API_KEY}" \
  'https://api.vultr.com/v2/instances?per_page=500')"

stray=()
for label in "${expected_labels[@]}"; do
  match="$(jq -r --arg l "${label}" \
    '.instances[]? | select(.label == $l) | "\(.id) (\(.main_ip))"' <<<"${instances}")"
  [[ -n "${match}" ]] && stray+=("${label} -> ${match}")
done

if [[ "${#stray[@]}" -eq 0 ]]; then
  echo "Destroy scope: state is empty and Vultr has no instance matching this profile's labels; already destroyed."
  exit 0
fi

{
  echo "::error::Refusing to report a successful destroy that would delete nothing."
  echo "Workspace ${ENV_STEPS_ROUTE_OUTPUTS_TERRAFORM_WORKSPACE} (state ${ENV_STEPS_ROUTE_OUTPUTS_STATE_KEY}) manages no instances, but Vultr still has ${#stray[@]} instance(s) declared by this profile:"
  printf '  - %s\n' "${stray[@]}"
  echo "They belong to a different workspace/state. Re-run destroy with the target_domains value that created them, or adopt them into this state first."
} >&2
exit 1
