# XConnect host owner cutover gate (2026-10-07)

The reviewed Playbooks owner revision for this batch is
`9d585e147348800b1603c4f7b0d8a6bcf0546007`. Publish that exact commit before
publishing the Toolkit caller commit. The caller must not be released with a
rewritten or unavailable owner SHA.

## Trusted SSH input

`xconnect-runtime-control.yml` and the external Gateway reconciliation stage
read the SSH identity and host trust from the same UAT deployment record:

- `kv/data/CICD/uat` field `SSH_PRIVATE_DEPLOY_KEY_B64`
- `kv/data/CICD/uat` field `SSH_KNOWN_HOSTS_B64`

`SSH_KNOWN_HOSTS_B64` must decode to a non-empty OpenSSH `known_hosts` file and
must contain the exact selected target. The Playbooks owner verifies the target
with `ssh-keygen -F` and uses `StrictHostKeyChecking=yes`. There is no keyscan or
trust-on-first-use fallback.

The repository configuration proves only the expected field name and read
path. It does not prove that `SSH_KNOWN_HOSTS_B64` is currently populated or
that its host keys match UAT. Seed and independently verify that field before
dispatching either caller.

The external persistent Gateway reconciliation uses its target-specific record
instead: `kv/data/prod/ulighthost-xconnect/tw-xconnect.svc.plus`. The host, user,
`ssh_private_key_b64`, and `known_hosts_b64` fields must come from that same
record. The repository does not prove that the new `known_hosts_b64` field is
currently populated or matches the target.

## Vault claim rollout

The role source binds the UAT role to `main`, environment `uat`, and exactly
these workflows:

- `.github/workflows/xconnect-zero-cloud.yaml`
- `.github/workflows/xconnect-runtime-control.yml`

The JSON change is configuration-as-code. An authorized operator must apply the
role update before the runtime workflow can authenticate. A repository test is
not evidence that the live Vault role was updated.

## Acceptance still required

The cutover is complete only after a UAT run records the exact owner SHA,
Toolkit SHA, GitHub run and attempt, selected target, verified SSH host-key
fingerprint, and the operation-specific receipt. XHTTP acceptance also requires
the effective Gateway or One runtime to match the reviewed address, TLS SNI,
path, mode, and Host contract. Private data-plane acceptance requires the
run-scoped marker probe to be removed through an `always()` cleanup and the
same-run evidence receipt to verify private HTTP and WireGuard evidence.

The called `.github/scripts/xconnect-lab/` and
`.github/scripts/xconnect-existing-one-uat/` legacy paths remain frozen until
those receipts exist. Their source presence, contract tests, and owner action
availability do not authorize deletion.
