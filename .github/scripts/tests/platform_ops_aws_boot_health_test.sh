#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script="${script_dir}/../platform-ops/provision/platform-ops_provision_verify-aws-boot-health.sh"
workflow="${script_dir}/../../workflows/selfhost-orchestrator.yml"
workdir="$(mktemp -d)"
trap 'rm -rf "${workdir}"' EXIT

mkdir -p "${workdir}/bin"
cat >"${workdir}/cmdb.json" <<'JSON'
{
  "hk-xconnect.onwalk.net": {
    "name": "agent-proxy-hk",
    "instance_id": "i-hk",
    "cloud_region": "ap-east-1"
  }
}
JSON

cat >"${workdir}/bin/aws" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"${TEST_WORKDIR}/aws-commands.log"
case "$*" in
  *describe-instance-status*) printf '%s\n' "${TEST_INSTANCE_STATUS}" ;;
  *get-console-output*) printf '%s\n' 'cloud-init: ssh.service failed to start' ;;
  *) echo "unexpected aws invocation: $*" >&2; exit 1 ;;
esac
SCRIPT
chmod +x "${workdir}/bin/aws" "${script}"

TEST_WORKDIR="${workdir}" \
TEST_INSTANCE_STATUS='running ok ok' \
PATH="${workdir}/bin:${PATH}" \
CMDB_FILE="${workdir}/cmdb.json" \
AWS_BOOT_HEALTH_TIMEOUT_SECONDS=0 \
bash "${script}" >"${workdir}/healthy.log"

grep -Fq 'all 1 instance(s) passed' "${workdir}/healthy.log"
grep -Fq -- '--region ap-east-1 --instance-ids i-hk --include-all-instances' "${workdir}/aws-commands.log"
if grep -Fq 'get-console-output' "${workdir}/aws-commands.log"; then
  echo "healthy instances must not request console output" >&2
  exit 1
fi

: >"${workdir}/aws-commands.log"
if TEST_WORKDIR="${workdir}" \
  TEST_INSTANCE_STATUS='running ok initializing' \
  PATH="${workdir}/bin:${PATH}" \
  CMDB_FILE="${workdir}/cmdb.json" \
  AWS_BOOT_HEALTH_TIMEOUT_SECONDS=0 \
  bash "${script}" >"${workdir}/failed.log" 2>&1; then
  echo "an instance with an initializing status must fail at the deadline" >&2
  exit 1
fi

grep -Fq 'did not pass both EC2 status checks' "${workdir}/failed.log"
grep -Fq 'cloud-init: ssh.service failed to start' "${workdir}/failed.log"
grep -Fq -- '--region ap-east-1 --instance-id i-hk --latest' "${workdir}/aws-commands.log"
grep -Fq 'name: Verify AWS EC2 boot health' "${workflow}"
grep -Fq 'platform-ops_provision_verify-aws-boot-health.sh' "${workflow}"

echo "platform_ops_aws_boot_health_test: PASS"
