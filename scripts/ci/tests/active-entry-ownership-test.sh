#!/usr/bin/env bash
set -euo pipefail
checker="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/active-entry-ownership-verify.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fixture() {
  rm -rf "$tmp/repo"; mkdir -p "$tmp/repo/.github/scripts" "$tmp/repo/.github/workflows" "$tmp/repo/scripts/serverless_uat"
  git -C "$tmp/repo" init -q
  printf 'schema: 1\nlegacy: []\nretired_workflow_entries: []\n' > "$tmp/registry"
}
reject() { if bash "$checker" "$tmp/repo" "$tmp/registry" > "$tmp/log" 2>&1; then echo "Unexpected acceptance: $1" >&2; exit 1; fi; echo "PASS reject $1"; }
fixture; printf 'docker run image\n' > "$tmp/repo/.github/scripts/run_k6_performance_test.sh"; reject 'active _test.sh executor'
fixture; printf 'timeout "60m" ansible-playbook observe.yml\n' > "$tmp/repo/.github/scripts/observe.sh"; reject 'timeout-prefixed execution'
fixture; printf 'bash scripts/serverless_uat/provider.sh\n' > "$tmp/repo/.github/scripts/wrapper.sh"; printf 'gcloud run deploy target\n' > "$tmp/repo/scripts/serverless_uat/provider.sh"; reject 'wrapper plus downstream Provider executor'
fixture; printf 'ssh target true\n' > "$tmp/repo/.github/scripts/old.sh"
digest="$(shasum -a 256 "$tmp/repo/.github/scripts/old.sh" | awk '{print $1}')"
printf 'schema: 1\nlegacy:\n  - path: .github/scripts/old.sh\n    sha256: %s\nretired_workflow_entries: []\n' "$digest" > "$tmp/registry"
bash "$checker" "$tmp/repo" "$tmp/registry" >/dev/null; echo 'PASS existing frozen debt'
printf 'echo no_marker\n' > "$tmp/repo/.github/scripts/old.sh"; reject 'marker removal from frozen bytes'
fixture; printf 'gh workflow run owner.yml\n' > "$tmp/repo/.github/scripts/dispatch.sh"
bash "$checker" "$tmp/repo" "$tmp/registry" >/dev/null; echo 'PASS pure control dispatch'
fixture; printf 'schema: 1\nlegacy: []\nretired_workflow_entries: [.github/scripts/wrapper.sh]\n' > "$tmp/registry"
printf 'steps:\n  - run: bash .github/scripts/wrapper.sh\n' > "$tmp/repo/.github/workflows/caller.yml"; reject 'retired formal wrapper route'
echo '7 active-entry checks passed without runtime execution.'
