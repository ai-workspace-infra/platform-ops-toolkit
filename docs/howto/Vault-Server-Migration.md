# Migrate vault.svc.plus to a new Raft cluster

Goals and task links: `docs/planning/vault-server-goals.md` (epic
[#958](https://github.com/ai-workspace-infra/platform-ops-toolkit/issues/958)).

The existing node is converted in place to single-node Raft (Vault's own local
storage, no PostgreSQL afterwards). The new nodes then join it over XConnect,
take leadership, and the old node is removed. The only downtime is the short
in-place conversion. Everything runs from **Actions → Vault server**
(`vault-server.yml`) with `deploy_action=none`, one `service_stage` per
dispatch. Every stage checks live state first and refuses to continue if the
previous step (including a manual one) is not done.

GitHub Actions never receives a root token, unseal shares or an operator
credential. Actions that change a live Vault need the `confirm` phrase shown
below; the protected `prod` Environment still asks for approval.

## One-time preparation

1. **Vault roles**, from an authorized admin terminal on `main`:
   ```bash
   bash scripts/vault/bootstrap_shared_gcp_roles.sh --apply   # adds legacy-ssh, snapshot, raft-operator
   VAULT_LEGACY_SSH_USER=vault-migrate bash scripts/vault/bootstrap_shared_ssh_ca.sh --apply
   bash scripts/vault/bootstrap_shared_ssh_ca.sh --print-ca    # public key for step 2
   ```
2. **Existing node** (once, as root): create the `vault-migrate` user with
   passwordless sudo, install the printed CA key as
   `/etc/ssh/vault-user-ca.pub`, add `TrustedUserCAKeys /etc/ssh/vault-user-ca.pub`
   and `AuthorizedPrincipalsFile /etc/ssh/auth_principals/%u` to `sshd_config`,
   write `vault-migrate` into `/etc/ssh/auth_principals/vault-migrate`, and
   reload sshd. Make sure the host has no swap and has `nftables` installed.
   CI then logs in with 30-minute certificates only.
3. **Backup target**: write `access_key_id` / `secret_access_key` for an
   S3-compatible bucket to `kv/CICD/shared/vault-backup`; generate an age key
   pair offline and keep the private key off every server and CI.
4. **GitOps**: add `automation.raft_operator_role`, `migration` and `backup` to
   `resources/svc.plus/shared/vault/server.yaml` (template in the goals file).
   `migration.source.overlay_address` is the XConnect IP assigned to the old
   node; Raft never uses a public address.

## Stages

| # | `service_stage` | `confirm` | You do afterwards |
| --- | --- | --- | --- |
| 1 | `node-preflight` | — | — |
| 2 | `node-process-metrics` | — | check the dashboards |
| 3 | `legacy-preflight` | — | read the warnings (key file on disk, versions) |
| 4 | `legacy-convert-raft` | `CONVERT-VAULT-TO-RAFT` | unseal the old node with its existing key; check `vault.svc.plus` |
| 5 | `vault-snapshot` | — | restore drill on a throwaway node (M3) |
| 6 | `vault-join-legacy` | — | unseal each new node (existing key); `vault operator raft list-peers` shows all voters |
| 7 | `vault-raft-verify` | — | — |
| 8 | `vault-cutover` | `MOVE-VAULT-LEADER` | move `vault.svc.plus` DNS to the new entry point |
| 9 | `vault-remove-legacy` | `REMOVE-LEGACY-VAULT-PEER` | **rekey, rotate, revoke the old root token, delete `vault_init.json`** |

What each changing stage does:

- `legacy-convert-raft`: on the old host, backs up `vault_storage`
  (`/var/backups/vault-migration`, 0600, sha256), stops Vault, runs
  `vault operator migrate` from local PostgreSQL (read-only, 127.0.0.1) to
  `/opt/vault/data`, loads the `vault_port_guard` nftables table (8200/8201
  only from loopback and the overlay interface), then runs the reviewed
  `deploy_vault_single_raft.yml`. PostgreSQL itself is never restarted or
  written. Undo with `legacy-convert-rollback` (`ROLLBACK-VAULT-TO-POSTGRESQL`);
  writes made to Raft since the conversion are not carried back.
- `vault-snapshot`: snapshot through the API with a snapshot-only token,
  checksum verification, age encryption on the runner, upload of the
  ciphertext only.
- `vault-cutover`: steps the old node down (retrying if it wins again) until
  a new node leads. The old node keeps serving by forwarding to the new
  leader, so DNS can move at your pace.
- `vault-remove-legacy`: removes only the declared source peer, only when a
  new node leads and all new nodes are voters, then stops and disables Vault
  on the old host (its data stays until decommissioning).

After step 9, drop `spec.migration` from GitOps; `vault-raft-verify` then
checks only the new nodes.
