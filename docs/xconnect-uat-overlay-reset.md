# UAT XConnect overlay reset and address/key policy

## Environment boundary

UAT may use a destructive overlay-only reset for repeatable integration tests.
Production must never use this command. Production changes are forward-only
schema migrations with a backup, validation, and an operator-approved
maintenance window. They must preserve users, subscriptions, invoices, and
historical usage data; no business-table cascade or schema reset is allowed.

## UAT reset scope

The UAT reset removes only the formal Accounts overlay state:

- `overlay_networks`
- `overlay_invites`
- `overlay_devices`
- `overlay_device_credentials`
- `overlay_enrollment_sessions`
- `overlay_signed_config_acks`
- `overlay_registrations`

The command uses an explicit confirmation token, obtains the Supabase session
pooler URI from Vault, locks these tables, deletes them in one transaction, and
verifies zero rows afterward. It does not delete `users`, application data,
subscription/billing/usage tables, Vault records, or any node-local state. It
also does not use a schema-wide `CASCADE` because that would make the reset
boundary unsafe.

Run locally with a Vault token that can read the UAT Supabase record:

```bash
export VAULT_ADDR=https://vault.svc.plus
bash scripts/serverless_uat/reset_xconnect_overlay.sh \
  --confirm RESET-UAT-XCONNECT-OVERLAY
```

The reset is destructive for UAT overlay metadata and should be followed by a
fresh network/bootstrap/invite flow. It is not a production reset procedure.

## Transition cleanup status

UAT still contains the empty compatibility tables `overlay_nodes` and
`overlay_config_acks`. The current Accounts compatibility handlers for the
legacy `/api/overlay` and node heartbeat routes still reference them, so they
are intentionally not dropped in this reset. After Portal/BFF and all callers
move to `/api/overlay/v1`, remove those tables in a separately versioned
Accounts migration after a zero-reference check. The new v1 tables are the
seven tables listed above.

The current v1 schema fields are retained until that cutover. In particular,
`policy_json` and `transport_auth_id` are still consumed by the current
Accounts implementation; they should later become a policy digest/reference
and a Vault secret reference in an additive migration. Do not remove them by
hand from UAT or PROD while the deployed binary still selects them.

### Cleanup inventory and order

| Object | Decision | Removal gate |
| --- | --- | --- |
| `overlay_nodes` | Transitional legacy gateway read/write model; keep empty for compatibility now | Remove legacy `/api/overlay` and heartbeat code, prove zero references in source and runtime logs, then drop in a versioned migration |
| `overlay_config_acks` | Transitional ACK model; keep empty for compatibility now | Move all ACK writes/reads to `overlay_signed_config_acks`, verify the Portal/BFF and Gateway/One smoke test, then drop in the same or a later migration |
| `overlay_networks.policy_json` | Overly large policy payload in the metadata row | Add `policy_digest`/`policy_ref`, make the signer and Portal use the reference, backfill and verify, then drop the JSON column |
| `overlay_networks.transport_auth_id` | Transport credential currently coupled to the network row | Replace with a Vault locator/reference; the signer resolves the runtime credential without persisting the secret in Accounts, then drop the raw field |
| `overlay_devices.user_id` | Duplicate owner representation beside `user_uuid` | Normalize all queries and foreign-key checks to the tenant/account UUID, backfill verification, then drop only the duplicate text column |
| `overlay_invites`, `overlay_device_credentials`, `overlay_enrollment_sessions`, `overlay_signed_config_acks`, `overlay_registrations` | Required v1 lifecycle and audit metadata | Retain; apply TTL/retention cleanup to expired token digests and old ACKs without deleting active device or account metadata |

The cleanup must be implemented in this order: code cutover and reference
check, additive replacement columns, backfill/verification, compatible
deployment, retention cleanup, and only then removal of the obsolete object.
The migration must fail closed if an old table or column is still referenced.

## Production migration contract

The production path is a maintenance-window migration:

1. stop or drain Accounts writers;
2. take and verify a Supabase backup/export, including subscription and usage
   tables;
3. run additive, idempotent migrations for overlay metadata only;
4. validate row counts and foreign-key/index health;
5. deploy the compatible Accounts release and perform a signed-config smoke
   test;
6. resume traffic and retain the backup plus migration evidence.

Destructive cleanup of old overlay rows, if ever required in PROD, must be a
separately reviewed, tenant-scoped retention operation. It cannot be part of a
schema migration and cannot use `DROP`, `TRUNCATE ... CASCADE`, or a broad
`DELETE` over business tables.

The PROD migration must use `ALTER TABLE ... ADD COLUMN`, backfill in bounded
batches, and only remove a legacy column/table in a later release after the
previous release no longer reads it. A rollback plan must restore the previous
Accounts binary before any destructive DDL; the backup must include users,
subscriptions, invoices, and historical usage even though those tables are
outside the XConnect overlay scope.

## Gateway WireGuard address

The cloud lab no longer embeds a Gateway address in `deploy.sh`, probe code, or
the Accounts bootstrap payload. Resolution order is:

1. optional `workflow_dispatch` input `gateway_wireguard_address`;
2. the reviewed GitOps value `spec.overlay.gateway_address`.

The value must be a canonical IPv4 `/32`, belong to `spec.overlay.cidr`, and be
different from the One address. The default declaration can remain
`10.77.0.1/32`, but a UAT run may select another free address without editing
the deployment script. The HTTP probe, route check, handoff, and bootstrap
payload all use the resolved value.

## WireGuard key handling

WireGuard keys are generated at node initialization (`wg genkey`/the released
Gateway or One runtime), not by the database and not by GitOps:

- only the public key, address, role, device/network IDs, status, and last-seen
  metadata are sent to Accounts;
- private keys remain in the node state directory with owner-only permissions;
- invites, enrollment tokens, credentials, TLS keys, VLESS IDs, and Xray
  configuration are not printed or committed.

For a persistent node that needs disaster-recovery backup, an explicit future
Vault record may hold the private key under a node-scoped path such as
`kv/data/uat/xconnect-one/<node-id>`, with `wireguard_private_key_b64` and a
matching public-key fingerprint. That backup must be opt-in and read only by
the node bootstrap role; it is not needed for ephemeral Spot runs. The current
transport-only and cloud-lab flows intentionally keep ephemeral private keys
node-local to reduce secret duplication.

## Accounts storage boundary

Accounts should remain a lightweight control-plane metadata store: network and
device identity, tenant/owner relation, public WireGuard identity, addresses,
policy references or digests, lifecycle status, expiry, generation, and ACK
metadata. Full signed configurations and runtime secrets belong in the
service/runtime boundary and Vault, not in rows or GitOps. The reset script is
deliberately limited to the overlay metadata tables so this boundary can be
changed without touching application accounts.
