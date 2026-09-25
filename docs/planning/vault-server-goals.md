# Vault Server goals

Planning record for epic
[#958](https://github.com/ai-workspace-infra/platform-ops-toolkit/issues/958).
Goals are set by the project owner; each goal lists its tasks and the
evidence that marks it done. `scripts/planning/sync_vault_server_project.sh`
mirrors this file into the org GitHub Project (a "Goal" field on every issue).

**Outcome:** pipeline-driven (`vault-server.yml`, a single workflow),
XConnect Gateway/One + Playbook + monitoring, move `vault.svc.plus` from its
existing node to any cloud — Vault itself with local Raft storage, one or three
nodes, no PostgreSQL dependency.

**Principles:** simple, reliable, security first, always backed up, always
movable. CI never holds root tokens, unseal shares or operator credentials;
init, unseal, quorum confirmation and rekey stay manual.

| Goal | Objective | Tasks | Done when | Owner target |
| --- | --- | --- | --- | --- |
| G1 Foundation | Provider-neutral pipeline merged and authorized | #959 A1, #960 A2, #961 A3 | `vault-server.yml` on `main`; GitOps declaration merged; all shared JWT roles `--check` OK; `prod` requires review | _set_ |
| G2 New nodes observable | New nodes reachable, verified and monitored before any Vault change | #962 B1, #963 B2, #966 B5 | preflight green; private Raft rule verified live; node/process exporter + Vector metrics visible | _set_ |
| G3 Zero-trust network | XConnect overlay joins new nodes, the old node, the operator Mac and CI | #967 C1 – #972 C6 | overlay IPs/internal DNS in GitOps; Mac-only SSH policy; public SSH rule removed | _set_ |
| G4 Migration | Existing Vault converted in place and moved to the new cluster without data loss | #974, #975 M1 – #980 M6 | old node on Raft; encrypted snapshot off-site and restore drill passed; new nodes voters; leadership on a new node; old peer removed; CI reads never interrupted | _set_ |
| G5 Hardening & retirement | Nothing from the old node can unseal or reach the new cluster | #981 M7, #982 M8 | rekey + rotate done; old root token revoked; `vault_init.json` gone; Raft on private addresses; old host holds no Vault data | _set_ |
| G6 Portability | Same stages deploy a fresh 1- or 3-node cluster on GCP, other clouds or a VPS | #964 B3, #965 B4, #973 D1 | fresh GCP run and one VPS run complete with the same GitOps service declaration | _set_ |

## Pipeline stages (one dispatch each; every stage checks live state first)

| Stage | Path | Checks before | Does | Manual after |
| --- | --- | --- | --- | --- |
| `migrate-auto` | migration | live state | picks and runs the next `migrate-*` step below | whatever it names, then dispatch again |
| `node-preflight` | any | SSH, sudo, no swap | — | — |
| `node-process-metrics` | any | access | exporters + Vector | — |
| `migrate-preflight` | migration | old node unsealed, disk, storage, key file | read-only report | — |
| `migrate-convert` | migration | old node unsealed, overlay address | backup, stop, PG→Raft in place, port guard, single-node Raft | unseal (existing key) |
| `migrate-rollback` | migration | access | restore PostgreSQL-backed Vault | unseal |
| `vault-snapshot` | any | — | Raft snapshot → age-encrypted → S3 | keep age key offline |
| `migrate-join` | migration | old node Raft + active, new nodes empty | new nodes join over overlay | unseal each; `raft list-peers` |
| `migrate-cutover` | migration | Raft quorum (old + new) | step old node down | move DNS |
| `migrate-remove` | migration | old node standby | remove old peer, stop old Vault | M7 rekey/rotate/revoke |
| `fresh-leader` / `fresh-peers` | fresh | access / leader unsealed | install | init + unseal / unseal |
| `vault-raft-verify` | any | Raft quorum | — | `raft list-peers` |

## GitOps additions for the migration

```yaml
# resources/svc.plus/shared/vault/server.yaml (spec)
automation:
  raft_operator_role: github-actions-platform-ops-toolkit-shared-vault-raft-operator
migration:
  raft_network: overlay            # private once the Gateway routes the VPC
  overlay_interface: xconone0
  source:
    id: jp-xhttp-contabo
    address: jp-xhttp-contabo.svc.plus
    ssh_port: 22
    ssh_user: vault-migrate
    ssh_host_ed25519: <pinned Ed25519 host key>
    overlay_address: <assigned XConnect IP>
  ssh_ca:
    role: github-actions-platform-ops-toolkit-shared-vault-legacy-ssh
    sign_path: ssh-client-signer/sign/vault-legacy-ops
backup:
  snapshot_role: github-actions-platform-ops-toolkit-shared-vault-snapshot
  age_recipient: <age1… public key; private key offline>
  destination: s3://<bucket>/vault/shared
  endpoint: https://<s3-endpoint>
  region: <region>
  credentials_path: kv/data/CICD/shared/vault-backup
```

## Status log

| Date | Change |
| --- | --- |
| 2026-09-25 | Plan created; provider-neutral split and migration stages implemented (not yet run live) |
| 2026-09-25 | Single workflow (#985); host-side migration moved to playbooks (playbooks#488); stages renamed into node-/vault-/fresh-/migrate- groups; `migrate-auto` added |
