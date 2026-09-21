#!/usr/bin/env bash
set -euo pipefail

: "${GH_TOKEN:?GH_TOKEN is required}"
: "${GH_REPO:?GH_REPO is required}"
: "${CHILD_WORKFLOW:?CHILD_WORKFLOW is required}"
: "${DEPLOY_ACTION:?DEPLOY_ACTION is required}"
: "${ACCOUNT:?ACCOUNT is required}"
: "${GITOPS_REF:?GITOPS_REF is required}"
: "${IAC_REF:?IAC_REF is required}"
: "${TARGET_DOMAIN_BASE:?TARGET_DOMAIN_BASE is required}"

[[ "${TARGET_DOMAIN_BASE}" == "onwalk.net" ]] || {
  echo "::error::UAT Akamai namespace matrix requires target_domain_base=onwalk.net" >&2
  exit 1
}
case "${DEPLOY_ACTION}" in
  plan|apply) ;;
  *) echo "::error::namespace matrix accepts only plan or apply, got '${DEPLOY_ACTION}'" >&2; exit 1 ;;
esac

workspaces=(open-platform web-saas ai-workspace agent-proxy-jp agent-proxy-us agent-proxy-sg)

dispatch_and_wait() {
  local workspace="$1"
  local action="$2"
  local dispatch_started run_id=""
  dispatch_started="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  payload="$(jq -n \
    --arg action "${action}" \
    --arg account "${ACCOUNT}" \
    --arg workspace "${workspace}" \
    --arg gitops_ref "${GITOPS_REF}" \
    --arg iac_ref "${IAC_REF}" \
    '{ref:"main", inputs:{deploy_action:$action, vault_env_path:"uat", project:"svc.plus", account:$account, workspace:$workspace, resource_manifest:("resources/svc.plus/uat/akamai/" + $workspace + ".yaml"), gitops_repo_name:"ai-workspace-infra/gitops", gitops_repo_ref:$gitops_ref, iac_ref:$iac_ref}}')"
  gh api --method POST "repos/${GH_REPO}/actions/workflows/${CHILD_WORKFLOW}/dispatches" \
    --input - <<<"${payload}" >/dev/null

  for _ in $(seq 1 30); do
    run_id="$(gh run list --repo "${GH_REPO}" --workflow "${CHILD_WORKFLOW}" \
      --event workflow_dispatch --limit 20 \
      --json databaseId,createdAt,headBranch \
      --jq "[.[] | select(.headBranch == \"main\" and .createdAt >= \"${dispatch_started}\")] | sort_by(.createdAt) | last | .databaseId // empty")"
    if [[ -n "${run_id}" ]]; then
      break
    fi
    sleep 2
  done
  [[ -n "${run_id}" ]] || {
    echo "::error::could not locate dispatched ${CHILD_WORKFLOW} run for ${workspace}" >&2
    exit 1
  }

  echo "${workspace}: ${action} run ${run_id}"
  gh run watch "${run_id}" --repo "${GH_REPO}" --exit-status
  printf '%s\n' "${run_id}"
}

for workspace in "${workspaces[@]}"; do
  echo "::group::Akamai UAT namespace ${workspace} (${DEPLOY_ACTION})"
  apply_run="$(dispatch_and_wait "${workspace}" "${DEPLOY_ACTION}" | tail -n1)"

  if [[ "${DEPLOY_ACTION}" == "apply" ]]; then
    plan_run="$(dispatch_and_wait "${workspace}" plan | tail -n1)"
    plan_log="$(mktemp)"
    gh run view "${plan_run}" --repo "${GH_REPO}" --log >"${plan_log}"
    if ! grep -Eq 'No changes\.|Plan: 0 to add, 0 to change, 0 to destroy\.' "${plan_log}"; then
      echo "::error::post-apply plan for ${workspace} is not 0/0/0" >&2
      grep -E 'No changes\.|Plan: [0-9]+ to add, [0-9]+ to change, [0-9]+ to destroy\.' "${plan_log}" >&2 || true
      exit 1
    fi
    echo "${workspace}: post-apply plan is 0/0/0"
    rm -f "${plan_log}"
  fi
  echo "::endgroup::"
done
