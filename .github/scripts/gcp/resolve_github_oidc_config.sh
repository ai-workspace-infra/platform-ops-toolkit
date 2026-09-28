#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd -P)"
exec "${repo_root}/scripts/cloud/bootstrap/gcp/resolve_github_oidc_config.sh" "$@"
