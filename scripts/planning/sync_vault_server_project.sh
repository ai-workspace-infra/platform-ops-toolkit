#!/usr/bin/env bash
# Mirror docs/planning/vault-server-goals.md into an org GitHub Project.
#
# Run locally after:
#   gh auth login
#   gh auth refresh -s project,read:org
#
# Usage: bash scripts/planning/sync_vault_server_project.sh [PROJECT_TITLE]
# Idempotent: reuses the project and field, re-adding an issue is a no-op.
set -euo pipefail

owner=ai-workspace-infra
repo=platform-ops-toolkit
title="${1:-Vault Server: migrate vault.svc.plus to any cloud}"

# issue -> goal (keep in sync with docs/planning/vault-server-goals.md)
declare -A goals=(
  [958]="Epic"
  [959]="G1 Foundation" [960]="G1 Foundation" [961]="G1 Foundation"
  [962]="G2 New nodes observable" [963]="G2 New nodes observable" [966]="G2 New nodes observable"
  [967]="G3 Zero-trust network" [968]="G3 Zero-trust network" [969]="G3 Zero-trust network"
  [970]="G3 Zero-trust network" [971]="G3 Zero-trust network" [972]="G3 Zero-trust network"
  [974]="G4 Migration" [975]="G4 Migration" [976]="G4 Migration" [977]="G4 Migration"
  [978]="G4 Migration" [979]="G4 Migration" [980]="G4 Migration"
  [981]="G5 Hardening & retirement" [982]="G5 Hardening & retirement"
  [964]="G6 Portability" [965]="G6 Portability" [973]="G6 Portability"
)
options="Epic,G1 Foundation,G2 New nodes observable,G3 Zero-trust network,G4 Migration,G5 Hardening & retirement,G6 Portability"

command -v gh >/dev/null && command -v jq >/dev/null || { echo "gh and jq are required" >&2; exit 1; }
gh auth status >/dev/null

number="$(gh project list --owner "${owner}" --format json --limit 200 |
  jq -r --arg title "${title}" '.projects[] | select(.title == $title) | .number' | head -n 1)"
if [[ -z "${number}" ]]; then
  number="$(gh project create --owner "${owner}" --title "${title}" --format json | jq -r .number)"
  echo "created project #${number}"
fi
project_id="$(gh project view "${number}" --owner "${owner}" --format json | jq -r .id)"

field="$(gh project field-list "${number}" --owner "${owner}" --format json | jq -c '.fields[] | select(.name == "Goal")')"
if [[ -z "${field}" ]]; then
  gh project field-create "${number}" --owner "${owner}" --name Goal \
    --data-type SINGLE_SELECT --single-select-options "${options}" >/dev/null
  field="$(gh project field-list "${number}" --owner "${owner}" --format json | jq -c '.fields[] | select(.name == "Goal")')"
fi
field_id="$(jq -r .id <<<"${field}")"

for issue in $(printf '%s\n' "${!goals[@]}" | sort -n); do
  goal="${goals[${issue}]}"
  option_id="$(jq -r --arg goal "${goal}" '.options[] | select(.name == $goal) | .id' <<<"${field}")"
  [[ -n "${option_id}" ]] || { echo "Goal option '${goal}' is missing on the project field" >&2; exit 1; }
  item_id="$(gh project item-add "${number}" --owner "${owner}" \
    --url "https://github.com/${owner}/${repo}/issues/${issue}" --format json | jq -r .id)"
  gh project item-edit --project-id "${project_id}" --id "${item_id}" \
    --field-id "${field_id}" --single-select-option-id "${option_id}" >/dev/null
  echo "#${issue} -> ${goal}"
done
echo "https://github.com/orgs/${owner}/projects/${number}"
