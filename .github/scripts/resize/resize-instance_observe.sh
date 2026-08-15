#!/usr/bin/env bash
set -euo pipefail

: "${OBSERVATION_SECONDS:=1800}"
echo "Keeping the source instance during the ${OBSERVATION_SECONDS}s observation window."
sleep "${OBSERVATION_SECONDS}"
