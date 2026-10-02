#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
canonical="${repo_root}/scripts/cloud/bootstrap/iam/bootstrap_zitadel_kv.sh"

test -x "${canonical}" || { echo "ZITADEL bootstrap helper is not executable: ${canonical}" >&2; exit 1; }
bash -n "${canonical}"

grep -Fq 'shared/iam' "${canonical}"
grep -Fq 'shared/databases' "${canonical}"
grep -Fq -- '--check' "${canonical}"
grep -Fq -- '--apply' "${canonical}"
grep -Fq -- '--generate-missing' "${canonical}"
grep -Fq 'login_session_cookie_secret' "${canonical}"
grep -Fq 'ZITADEL_MASTERKEY' "${canonical}"
grep -Fq 'POSTGRESQL_ADMIN_PASSWORD' "${canonical}"
grep -Fq 'vault kv put' "${canonical}"
grep -Fq 'openssl rand' "${canonical}"

for forbidden_command in 'exec terraform' 'exec docker' 'terraform apply' 'terraform destroy' 'docker compose' 'aws ' 'gcloud compute' 'curl .*v1'; do
  if grep -Eiq "${forbidden_command}" "${canonical}"; then
    echo "ZITADEL KV bootstrap must not execute ${forbidden_command}" >&2
    exit 1
  fi
done

if grep -Eq 'echo .*ZITADEL_(MASTERKEY|ADMIN_PASSWORD|PG_PASSWORD)|echo .*POSTGRESQL_ADMIN_PASSWORD' "${canonical}"; then
  echo "ZITADEL KV bootstrap must not print secret values" >&2
  exit 1
fi

# The former scripts/iam/ wrapper is gone; a second entry point must not come back.
if [[ -e "${repo_root}/scripts/iam/bootstrap_zitadel_kv.sh" ]]; then
  echo "scripts/iam/bootstrap_zitadel_kv.sh must not exist: call the canonical path" >&2
  exit 1
fi
echo "zitadel_bootstrap_kv_contract_test: PASS"
