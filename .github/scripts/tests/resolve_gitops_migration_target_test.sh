#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
resolver="${script_dir}/../serverless/resolve_gitops_migration_target.sh"
workdir="$(mktemp -d)"
trap 'rm -rf "${workdir}"' EXIT

cat >"${workdir}/selfhost.json" <<'EOF'
{
  "kind": "EdgeRoutingConfig",
  "metadata": {"mode": "selfhost"},
  "spec": {
    "runtime": {"mode": "selfhost"},
    "public_endpoints": {
      "console": {"host": "console-selfhost-uat.onwalk.net"}
    }
  }
}
EOF

output="${workdir}/github-output"
GITOPS_ROUTING_CONFIG="${workdir}/selfhost.json" \
GITHUB_OUTPUT="${output}" \
  bash "${resolver}" >"${workdir}/stdout"
grep -Fxq 'target_host=console-selfhost-uat.onwalk.net' "${output}"
grep -Fq 'Resolved console SSH migration target from GitOps: console-selfhost-uat.onwalk.net' "${workdir}/stdout"

cat >"${workdir}/canonical.json" <<'EOF'
{
  "kind": "EdgeRoutingConfig",
  "metadata": {"mode": "selfhost"},
  "spec": {
    "runtime": {"mode": "selfhost"},
    "public_endpoints": {
      "console": {"host": "console-uat.onwalk.net"}
    }
  }
}
EOF

if GITOPS_ROUTING_CONFIG="${workdir}/canonical.json" GITHUB_OUTPUT="${output}" \
  bash "${resolver}" >"${workdir}/invalid-stdout" 2>"${workdir}/invalid-stderr"; then
  echo "resolver accepted a canonical DNS alias as an SSH target" >&2
  exit 1
fi
grep -Fq 'not a valid selfhost SSH target' "${workdir}/invalid-stderr"

echo "GitOps migration target resolver: passed"
