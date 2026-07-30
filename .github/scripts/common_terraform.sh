#!/usr/bin/env bash
set -eo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/common_require_env.sh"
require_env CONFIG_DIR

ACTION="${1:-${TF_ACTION:-apply}}"
make "${ACTION}" CONFIG_DIR=../../../../../${CONFIG_DIR}
