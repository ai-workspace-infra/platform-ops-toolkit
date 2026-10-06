# UAT Web SaaS empty-host acceptance closure

Incident: Toolkit run 37397087620, parent 37396670526, release
`daily-build-2026.10.06-r2`, target `web-saas-uat`.

The pre-deploy baseline 37396779666 captured `absent`. PostgreSQL was running
with only the default postgres database. Accounts/Billing could not authenticate
as account_user. A read-only probe correctly rejected this state; waiting alone
cannot create the database. Explicit `selfhost_init` is a separate UAT-only
operation, guarded against nonempty databases, not a side effect of deployment
or a legacy data import.

Playbooks owns account initialization and bounded, tag-matching service probes.
IaC Modules owns UAT Cloudflare reconciliation, including selection of host
objects from mixed CMDB metadata. Toolkit pins those owners, correlates exact
child runs, and requires Web SaaS acceptance before DNS publication. GitOps
retains desired topology and immutable service tags; no runtime CMDB is committed.

The original DNS patch PR #1312 failed the frozen Toolkit execution guard.
Its replacement establishes the IaC provider owner, switches the caller, verifies
UAT, then deletes the unused legacy executor and tests. Do not update the freeze
checksum to permit an in-place executor fix.

Evidence: pending live UAT. Local tests and merged owner PRs are not acceptance.
