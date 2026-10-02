#!/usr/bin/env bash
set -euo pipefail

# The script behaviour is tested next to the script, in
# iac_modules/scripts/pipeline/tests/aws_boot_health_test.sh. This keeps the
# workflow wiring honest: the gate has to stay in the provision job.
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
workflow="${script_dir}/../../workflows/selfhost-orchestrator.yml"

grep -Fq 'name: Verify AWS EC2 boot health' "${workflow}"
grep -Fq 'infra/iac_modules/scripts/pipeline/verify-aws-boot-health.sh' "${workflow}"

echo "platform_ops_aws_boot_health_test: PASS"
