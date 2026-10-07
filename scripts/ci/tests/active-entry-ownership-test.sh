#!/usr/bin/env bash
set -euo pipefail
checker="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/active-entry-ownership-verify.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fixture() {
  rm -rf "$tmp/repo"; mkdir -p "$tmp/repo/.github/scripts" "$tmp/repo/.github/workflows" "$tmp/repo/scripts/serverless_uat" "$tmp/repo/scripts/node_deploy"
  git -C "$tmp/repo" init -q
  printf 'schema: 1\nlegacy: []\nretired_workflow_entries: []\nvault_server_forbidden_entries: []\n' > "$tmp/registry"
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
fixture; printf 'import subprocess\nsubprocess.run(["ssh", "target", "true"], check=True)\n' > "$tmp/repo/scripts/node_deploy/new.py"; reject 'root Python subprocess SSH executor'
fixture
printf 'import subprocess\ndef execute():\n    subprocess.run(["gcloud", "run", "deploy", "service"], check=True)\n' > "$tmp/repo/scripts/node_deploy/executor.py"
printf 'from executor import execute\ndef main():\n    execute()\n' > "$tmp/repo/scripts/node_deploy/wrapper.py"
reject 'imported Python provider wrapper'
fixture; printf 'schema: 1\nlegacy: []\nretired_workflow_entries: [.github/scripts/wrapper.sh]\n' > "$tmp/registry"
printf 'steps:\n  - run: bash .github/scripts/wrapper.sh\n' > "$tmp/repo/.github/workflows/caller.yml"; reject 'retired formal wrapper route'
fixture
printf 'schema: 1\nlegacy: []\nretired_workflow_entries: []\nvault_server_forbidden_entries: ["uses: ./.github/actions/vault-node-stage", "uses: ./.github/actions/node-access-gcp", "scripts/node_deploy/auto_migration.py"]\n' > "$tmp/registry"
printf 'jobs:\n  stage:\n    steps:\n      - uses: ./.github/actions/vault-node-stage\n' > "$tmp/repo/.github/workflows/vault-server.yml"
reject 'Vault workflow local frozen action'
fixture
printf 'schema: 1\nlegacy: []\nretired_workflow_entries: []\nvault_server_forbidden_entries: ["uses: ./.github/actions/vault-node-stage", "uses: ./.github/actions/node-access-gcp"]\n' > "$tmp/registry"
printf 'jobs:\n  stage:\n    steps:\n      - uses: ai-workspace-infra/playbooks/.github/actions/vault-node-stage@0123456789012345678901234567890123456789\n      - uses: ./iac_modules/.github/actions/node-access-gcp\n' > "$tmp/repo/.github/workflows/vault-server.yml"
bash "$checker" "$tmp/repo" "$tmp/registry" >/dev/null; echo 'PASS exact owner paths'
fixture
printf 'jobs:\n  stage:\n    steps:\n      - uses: ai-workspace-infra/playbooks/.github/actions/vault-node-stage@main\n' > "$tmp/repo/.github/workflows/vault-server.yml"
reject 'unpinned Playbooks Vault action'
fixture; printf 'echo safe_control\n' > "$tmp/repo/.github/scripts/control.sh"
mkdir -p "$tmp/bin"; printf '#!/usr/bin/env bash\nexit 2\n' > "$tmp/bin/grep"; chmod +x "$tmp/bin/grep"
PATH="$tmp/bin:$PATH" reject 'source search dependency failure'
echo '13 active-entry checks passed without runtime execution.'
