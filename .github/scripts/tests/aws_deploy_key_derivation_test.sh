#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
script="${repo_root}/.github/scripts/platform-ops/provision/platform-ops_provision_derive-ssh-public-key.sh"
workflow="${repo_root}/.github/workflows/selfhost-orchestrator.yml"
workdir="$(mktemp -d)"
trap 'rm -rf "${workdir}"' EXIT

ssh-keygen -q -t ed25519 -N '' -f "${workdir}/id_deploy"
key_b64="$(base64 < "${workdir}/id_deploy" | tr -d '\n')"
GITHUB_ENV="${workdir}/github.env" SSH_PRIVATE_DEPLOY_KEY_B64="${key_b64}" bash "${script}"

derived="$(sed -n 's/^SSH_PUBLIC_DEPLOY_KEY=//p' "${workdir}/github.env")"
test "${derived}" = "$(ssh-keygen -y -f "${workdir}/id_deploy")"

grep -Fq 'SSH_PRIVATE_DEPLOY_KEY_B64 | SSH_PRIVATE_DEPLOY_KEY_B64' "${workflow}"
grep -Fq 'platform-ops_provision_derive-ssh-public-key.sh' "${workflow}"

echo "aws_deploy_key_derivation_test: PASS"
