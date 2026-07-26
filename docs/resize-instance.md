# Resize Instance Workflow

`resize-instance.yaml` is the explicit workflow for changing a Vultr instance
plan. The normal platform deployment must not be used to downgrade an existing
instance: Vultr rejects an in-place plan decrease such as
`vc2-4c-8gb -> vc2-2c-4gb`.

## Modes

- `same`: no infrastructure change.
- `upgrade`: imports the existing instance into an operation-local Terraform
  state, applies the higher plan, and then finishes with the normal health
  checks.
- `downgrade`: creates a snapshot, creates a replacement instance from that
  snapshot in an isolated Terraform state, checks the replacement through the
  target hostname, optionally switches the Cloudflare A record, retains the
  source during the observation window, and only deletes it when
  `destroy_old_instance=true` is explicitly selected.

The replacement module lives in the `iac_modules` repository at
`terraform-hcl-standard/vultr-vps/modules/resize-instance`.

## Safety gates

1. The preflight reads the current instance from Vultr and validates the plan
   direction before any mutation.
2. Downgrades require `confirm_resize=true`.
3. Replacement Terraform must contain exactly one create and zero deletes.
4. DNS is changed only after the replacement health check succeeds and
   `confirm_dns_switch=true` is selected.
5. The source instance is retained for the observation window by default.
6. Production runs should use the `resize-prod` GitHub Environment with an
   approval rule before allowing the workflow to continue.
7. Snapshot-based replacements require the target plan disk to be at least as
   large as the source disk. A smaller target disk is rejected during preflight
   before a snapshot is created; it requires an application-level backup and
   restore migration instead.

The workflow uses Vault OIDC credentials. It does not accept provider tokens as
workflow inputs and does not put credentials in Terraform state variables.
