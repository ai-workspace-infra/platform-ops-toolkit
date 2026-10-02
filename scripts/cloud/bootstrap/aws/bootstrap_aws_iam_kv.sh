#!/usr/bin/env bash
set -euo pipefail
exec "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../iam" && pwd)/bootstrap_identity_kv.sh" --integration aws "$@"
