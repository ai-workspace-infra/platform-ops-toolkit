#!/usr/bin/env bash
# Take a Vault Raft snapshot through the API, verify it, encrypt it with an
# age public key, and upload only the ciphertext to S3-compatible storage.
#
# Environment:
#   VAULT_ADDR, VAULT_TOKEN      token from the snapshot-only JWT role
#   BACKUP_AGE_RECIPIENT         age public key (the private key stays offline)
#   BACKUP_DESTINATION           s3://bucket/prefix
#   BACKUP_ENDPOINT              optional S3 endpoint URL
#   AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, AWS_REGION
#
# The snapshot is already encrypted by Vault's barrier, but it is still
# handled as sensitive: the plaintext file lives only in a private runner
# directory and is removed on exit.
set -euo pipefail
umask 077

for name in VAULT_ADDR VAULT_TOKEN BACKUP_AGE_RECIPIENT BACKUP_DESTINATION AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY; do
  [[ -n "${!name:-}" ]] || { echo "::error::${name} is required for vault-snapshot" >&2; exit 1; }
done
[[ "${BACKUP_AGE_RECIPIENT}" =~ ^age1[0-9a-z]{58}$ ]] || { echo "::error::BACKUP_AGE_RECIPIENT is not an age public key" >&2; exit 1; }
[[ "${BACKUP_DESTINATION}" =~ ^s3://[a-z0-9.-]+(/[A-Za-z0-9._/-]*)?$ ]] || { echo "::error::BACKUP_DESTINATION must be s3://bucket/prefix" >&2; exit 1; }
for command_name in curl tar sha256sum age aws; do
  command -v "${command_name}" >/dev/null 2>&1 || { echo "::error::${command_name} is required" >&2; exit 1; }
done

work="$(mktemp -d "${RUNNER_TEMP:-/tmp}/vault-snapshot.XXXXXX")"
trap 'rm -rf -- "${work}"' EXIT
stamp="$(date -u +%Y%m%dT%H%M%SZ)"
snapshot="${work}/vault-${stamp}.snap"

curl --fail --silent --show-error --max-time 600 \
  -H "X-Vault-Token: ${VAULT_TOKEN}" \
  -o "${snapshot}" "${VAULT_ADDR%/}/v1/sys/storage/raft/snapshot"
[[ -s "${snapshot}" ]] || { echo "::error::Vault returned an empty snapshot" >&2; exit 1; }

# A Raft snapshot is a gzip tar with meta.json, state.bin and SHA256SUMS.
mkdir "${work}/check"
tar -xzf "${snapshot}" -C "${work}/check"
for member in meta.json state.bin SHA256SUMS; do
  [[ -s "${work}/check/${member}" ]] || { echo "::error::snapshot is missing ${member}" >&2; exit 1; }
done
(cd "${work}/check" && sha256sum --check --quiet SHA256SUMS) || {
  echo '::error::snapshot checksums do not match' >&2
  exit 1
}
index="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("Index", "?"))' "${work}/check/meta.json")"
rm -rf "${work}/check"

encrypted="${snapshot}.age"
age --encrypt --recipient "${BACKUP_AGE_RECIPIENT}" --output "${encrypted}" "${snapshot}"
rm -f -- "${snapshot}"
digest="$(sha256sum "${encrypted}" | cut -d' ' -f1)"
size="$(du -h "${encrypted}" | cut -f1)"

endpoint_args=()
[[ -n "${BACKUP_ENDPOINT:-}" ]] && endpoint_args=(--endpoint-url "${BACKUP_ENDPOINT}")
target="${BACKUP_DESTINATION%/}/vault-${stamp}.snap.age"
aws "${endpoint_args[@]}" s3 cp --only-show-errors "${encrypted}" "${target}"
printf '%s  vault-%s.snap.age\n' "${digest}" "${stamp}" >"${work}/sha256"
aws "${endpoint_args[@]}" s3 cp --only-show-errors "${work}/sha256" "${target}.sha256"

report="Vault snapshot at Raft index ${index}: ${target} (${size}, sha256 ${digest})"
echo "${report}"
[[ -n "${GITHUB_STEP_SUMMARY:-}" ]] && echo "- ${report}" >>"${GITHUB_STEP_SUMMARY}"
