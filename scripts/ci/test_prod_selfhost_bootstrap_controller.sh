#!/usr/bin/env bash
# Existing controller guards migrated from Python mocks to Shell fixtures.
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
ENTRY="$ROOT/scripts/cloud/bootstrap/gcp/bootstrap_prod_selfhost.sh"
bash -n "$ENTRY"
bash "$ENTRY" --help >/dev/null
PRIVATE=$(mktemp -d)
trap 'rm -rf -- "$PRIVATE"' EXIT
mkdir -p "$PRIVATE/bin" "$PRIVATE/iac_modules/terraform-hcl-standard/gcp-cloud/scripts" "$PRIVATE/gitops"
export FIXTURE_IAC_REF FIXTURE_GITOPS_REF FIXTURE_DIRTY= FIXTURE_RECEIPT=valid
FIXTURE_IAC_REF=$(sed -n 's/^IAC_REF=//p' "$ENTRY")
FIXTURE_GITOPS_REF=$(sed -n 's/^GITOPS_REF=//p' "$ENTRY")
cat >"$PRIVATE/bin/git" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
directory=$2; shift 2
case "$1" in
  rev-parse) if [[ "$directory" == */iac_modules ]]; then echo "$FIXTURE_IAC_REF"; else echo "$FIXTURE_GITOPS_REF"; fi ;;
  remote) echo "https://github.com/ai-workspace-infra/${directory##*/}.git" ;;
  status) printf '%s' "$FIXTURE_DIRTY" ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$PRIVATE/bin/git"
export PATH="$PRIVATE/bin:$PATH"
BASE=(bash "$ENTRY" --iac-dir "$PRIVATE/iac_modules" --gitops-dir "$PRIVATE/gitops")
cat >"$PRIVATE/iac_modules/terraform-hcl-standard/gcp-cloud/scripts/bootstrap_prod_selfhost.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
stage=identity action=plan
while [[ $# -gt 0 ]]; do case "$1" in --stage) stage=$2;; --action) action=$2;; esac; shift 2; done
[[ -n "${GCP_BOOTSTRAP_ACCESS_TOKEN:-}" && -n "${TF_STATE_SECRET_KEY:-}" ]] || exit 1
result=review-required; [[ "$action" != apply ]] || result=converged
jq -n --arg iac "$FIXTURE_IAC_REF" --arg gitops "$FIXTURE_GITOPS_REF" --arg stage "$stage" --arg action "$action" --arg result "$result" --arg fixture "$FIXTURE_RECEIPT" \
  '{schema:1,owner:"iac_modules",scope:"prod-selfhost-bootstrap-only",project:"open-platform-prod",iac_ref:$iac,gitops_ref:$gitops,stage:$stage,action:$action,result:$result,approved_plan_sha256:("a"*64),database_cutover_approved:($fixture != "valid")}'
EOF
"${BASE[@]}" --check >"$PRIVATE/check.json"
jq -e '.result == "source-contract-verified" and .live_bootstrap_verified == false and .database_cutover_approved == false' "$PRIVATE/check.json" >/dev/null
reject() { if "$@" >"$PRIVATE/private.out" 2>"$PRIVATE/private.err"; then echo 'unsafe controller request accepted' >&2; exit 1; fi; }
export FIXTURE_DIRTY=' M source'
reject "${BASE[@]}" --check
export FIXTURE_DIRTY=
reject "${BASE[@]}" --action apply
reject "${BASE[@]}" --stage other
reject "${BASE[@]}" --bootstrap-account 'bad account'
export GCP_BOOTSTRAP_ACCESS_TOKEN=fixture-private-token
export TF_STATE_ENDPOINT=https://fixture.example TF_STATE_BUCKET=fixture-bucket TF_STATE_ACCESS_KEY=fixture-access TF_STATE_SECRET_KEY=fixture-secret TF_STATE_REGION=us-east-1
"${BASE[@]}" --action plan >"$PRIVATE/plan.json"
jq -e '.result == "review-required"' "$PRIVATE/plan.json" >/dev/null
"${BASE[@]}" --action apply --approved-plan-sha256 "$(printf 'a%.0s' {1..64})" >"$PRIVATE/apply.json"
jq -e '.result == "converged"' "$PRIVATE/apply.json" >/dev/null
export FIXTURE_RECEIPT=unsafe
reject "${BASE[@]}"
if rg -q 'fixture-private-token|fixture-secret' "$PRIVATE/plan.json" "$PRIVATE/apply.json" "$PRIVATE/private.out" "$PRIVATE/private.err"; then exit 1; fi
echo 'Shell controller pins sources and rejects dirty checkouts unsafe receipts and unreviewed apply.'
