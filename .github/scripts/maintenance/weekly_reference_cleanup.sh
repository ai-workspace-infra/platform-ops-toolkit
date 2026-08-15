#!/usr/bin/env bash
set -euo pipefail

# Destructive operations are intentionally explicit and API-based. The workflow
# invokes this script with DRY_RUN=false only for the scheduled run.

RETENTION_DAYS="${RETENTION_DAYS:-7}"
DRY_RUN="${DRY_RUN:-true}"
REPOSITORY="${GITHUB_REPOSITORY:-}"
DEFAULT_BRANCH="${DEFAULT_BRANCH:-}"

if [[ ! "$RETENTION_DAYS" =~ ^[1-9][0-9]*$ ]]; then
  echo "RETENTION_DAYS must be a positive integer" >&2
  exit 2
fi
if [[ "$DRY_RUN" != "true" && "$DRY_RUN" != "false" ]]; then
  echo "DRY_RUN must be true or false" >&2
  exit 2
fi
if [[ -z "$REPOSITORY" ]]; then
  REPOSITORY="$(gh repo view --json nameWithOwner --jq .nameWithOwner)"
fi
if [[ -z "$DEFAULT_BRANCH" ]]; then
  DEFAULT_BRANCH="$(gh repo view "$REPOSITORY" --json defaultBranchRef --jq .defaultBranchRef.name)"
fi

if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  SUMMARY_FILE="$GITHUB_STEP_SUMMARY"
else
  SUMMARY_FILE="$(mktemp)"
fi
: >"$SUMMARY_FILE"
TEMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TEMP_DIR"' EXIT

if cutoff_epoch="$(date -u -d "-${RETENTION_DAYS} days" +%s 2>/dev/null)"; then
  format_epoch() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }
else
  cutoff_epoch="$(date -u -v-"${RETENTION_DAYS}"d +%s)"
  format_epoch() { date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ; }
fi
now_iso="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
if [[ "$DRY_RUN" == true ]]; then
  mode="dry-run"
else
  mode="apply"
fi

echo "Repository: $REPOSITORY"
echo "Default branch: $DEFAULT_BRANCH"
echo "Retention window: $RETENTION_DAYS days (cutoff $(format_epoch "$cutoff_epoch"))"
echo "Mode: $mode"

# A conflicting local tag must never be force-updated. CI starts from a clean
# checkout; locally, continue with the existing refs and report the warning.
if ! git fetch origin --prune --tags; then
  echo "::warning::Some local tags could not be updated; no local tag is force-updated."
fi

stable_tag() {
  [[ "$1" == v* ]]
}

environment_prefix() {
  case "$1" in
    daily-build-*) echo daily-build ;;
    uat-daily-build-*) echo uat-daily-build ;;
    sit-*) echo sit ;;
    uat-*) echo uat ;;
    prod-*) echo prod ;;
    *) echo "" ;;
  esac
}

is_recent() {
  [[ -n "$1" && "$1" -ge "$cutoff_epoch" ]]
}

tag_inventory="$TEMP_DIR/tags"
git for-each-ref --format='%(refname:strip=2)|%(creatordate:unix)|%(creatordate:iso8601)' refs/tags >"$tag_inventory"

# Keep the newest deployable tag for each known environment family as a
# rollback floor. This exception is reported even when it is older than the
# configured recent window.
declare -A latest_tag_by_prefix=()
declare -A latest_epoch_by_prefix=()
while IFS='|' read -r tag created_epoch created_iso; do
  [[ -n "$tag" ]] || continue
  prefix="$(environment_prefix "$tag")"
  [[ -n "$prefix" && -n "$created_epoch" ]] || continue
  if [[ -z "${latest_epoch_by_prefix[$prefix]:-}" || "$created_epoch" -gt "${latest_epoch_by_prefix[$prefix]}" ]]; then
    latest_epoch_by_prefix[$prefix]="$created_epoch"
    latest_tag_by_prefix[$prefix]="$tag"
  fi
done <"$tag_inventory"

release_tags="$TEMP_DIR/releases"
if ! gh api --paginate "repos/$REPOSITORY/releases?per_page=100" --jq '.[].tag_name' >"$release_tags"; then
  echo "::error::Unable to determine GitHub Releases; refusing to delete tags."
  exit 1
fi

active_refs="$TEMP_DIR/active_refs"
: >"$active_refs"
if ! gh run list --repo "$REPOSITORY" --status in_progress --limit 100 --json headBranch --jq '.[].headBranch' >>"$active_refs"; then
  echo "::error::Unable to determine active workflow refs; refusing to delete refs."
  exit 1
fi
if ! gh api --paginate "repos/$REPOSITORY/deployments?per_page=100" --jq '.[].ref' >>"$active_refs"; then
  echo "::error::Unable to determine active deployment refs; refusing to delete refs."
  exit 1
fi

open_pr_heads="$TEMP_DIR/open_pr_heads"
if ! gh pr list --repo "$REPOSITORY" --state open --limit 200 --json headRefName --jq '.[].headRefName' >"$open_pr_heads"; then
  echo "::error::Unable to determine open pull-request heads; refusing to delete branches."
  exit 1
fi

tag_candidates="$TEMP_DIR/tag_candidates"
tag_retained=0
tag_candidate_count=0
echo
echo "Tag classification:"
while IFS='|' read -r tag created_epoch created_iso; do
  [[ -n "$tag" ]] || continue
  prefix="$(environment_prefix "$tag")"
  reason=""
  if stable_tag "$tag"; then
    reason="stable v* tag"
  elif is_recent "$created_epoch"; then
    reason="within ${RETENTION_DAYS}-day window"
  elif [[ -n "$prefix" && "${latest_tag_by_prefix[$prefix]:-}" == "$tag" ]]; then
    reason="rollback floor: newest ${prefix} tag"
  elif grep -Fxq "$tag" "$release_tags" || grep -Fxq "$tag" "$active_refs"; then
    reason="referenced by release or active deployment/workflow"
  elif git grep -F -l "$tag" -- . >/dev/null 2>&1; then
    reason="referenced by checked-out repository content"
  else
    printf '%s\n' "$tag" >>"$tag_candidates"
    tag_candidate_count=$((tag_candidate_count + 1))
    echo "  DELETE candidate: $tag ($created_iso)"
    continue
  fi
  tag_retained=$((tag_retained + 1))
  echo "  KEEP: $tag ($reason)"
done <"$tag_inventory"

branch_inventory="$TEMP_DIR/branches"
git for-each-ref --format='%(refname:strip=3)|%(committerdate:unix)|%(committerdate:iso8601)' refs/remotes/origin \
  | while IFS='|' read -r branch committed_epoch committed_iso; do
      [[ "$branch" == HEAD ]] || printf '%s|%s|%s\n' "$branch" "$committed_epoch" "$committed_iso"
    done >"$branch_inventory"

branch_candidates="$TEMP_DIR/branch_candidates"
branch_retained=0
branch_candidate_count=0
echo
echo "Branch classification:"
while IFS='|' read -r branch committed_epoch committed_iso; do
  [[ -n "$branch" ]] || continue
  reason=""
  if [[ "$branch" == "$DEFAULT_BRANCH" || "$branch" == main || "$branch" == master || "$branch" == develop || "$branch" == release/* ]]; then
    reason="protected branch pattern"
  elif is_recent "$committed_epoch"; then
    reason="within ${RETENTION_DAYS}-day grace window"
  elif grep -Fxq "$branch" "$open_pr_heads" || grep -Fxq "$branch" "$active_refs"; then
    reason="open PR or active deployment/workflow reference"
  elif ! git show-ref --verify --quiet "refs/remotes/origin/$branch" || ! git merge-base --is-ancestor "refs/remotes/origin/$branch" "refs/remotes/origin/$DEFAULT_BRANCH"; then
    reason="not proven merged into $DEFAULT_BRANCH"
  else
    printf '%s\n' "$branch" >>"$branch_candidates"
    branch_candidate_count=$((branch_candidate_count + 1))
    echo "  DELETE candidate: $branch ($committed_iso)"
    continue
  fi
  branch_retained=$((branch_retained + 1))
  echo "  KEEP: $branch ($reason)"
done <"$branch_inventory"

delete_ref() {
  local kind="$1" name="$2"
  if [[ "$DRY_RUN" == true ]]; then
    echo "DRY-RUN: would delete $kind $name"
  else
    gh api --method DELETE "repos/$REPOSITORY/git/refs/$kind/$name"
    echo "DELETED: $kind $name"
  fi
}

echo
echo "Applying explicit candidates:"
while IFS= read -r tag; do
  [[ -n "$tag" ]] && delete_ref tags "$tag"
done <"$tag_candidates"
while IFS= read -r branch; do
  [[ -n "$branch" ]] && delete_ref heads "$branch"
done <"$branch_candidates"

{
  echo "## Weekly reference cleanup"
  echo
  printf '%s\n' "- Repository: \`$REPOSITORY\`"
  printf '%s\n' "- Run: \`$now_iso\`"
  printf '%s\n' "- Retention window: \`${RETENTION_DAYS}\` days"
  printf '%s\n' "- Mode: \`$mode\`"
  printf '%s\n' "- Stable tags retained: \`$tag_retained\`"
  printf '%s\n' "- Tag deletion candidates: \`$tag_candidate_count\`"
  printf '%s\n' "- Branches retained: \`$branch_retained\`"
  printf '%s\n' "- Branch deletion candidates: \`$branch_candidate_count\`"
  echo
  echo 'Stable `v*` tags, `main`/protected branch patterns, recent refs, open-PR refs, active deployment refs, release refs, and unmerged branches are fail-closed and retained.'
  echo
  echo "### Explicit candidate lists"
  echo
  echo '```text'
  if [[ -s "$tag_candidates" ]]; then sed 's/^/tag: /' "$tag_candidates"; else echo 'tag: none'; fi
  if [[ -s "$branch_candidates" ]]; then sed 's/^/branch: /' "$branch_candidates"; else echo 'branch: none'; fi
  echo '```'
} >>"$SUMMARY_FILE"
