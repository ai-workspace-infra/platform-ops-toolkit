# UAT Web SaaS empty-host acceptance closure

Incident: Toolkit run 37397087620, parent 37396670526, release
`daily-build-2026.10.06-r2`, target `web-saas-uat`.

The pre-deploy baseline 37396779666 captured `absent`. PostgreSQL was running
with only the default postgres database. Accounts/Billing could not authenticate
as account_user. A read-only probe correctly rejected this state; waiting alone
cannot create the database. Explicit `selfhost_init` is a separate UAT-only
operation (`operation=deploy+init` for the selected UAT Web SaaS host), guarded against nonempty databases, not a side effect of ordinary deployment
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

## Correlated UAT evidence

- Toolkit caller: `bea4820f407cdc41ba6d9a1c18411d5b6479a78b` (PR #1313).
- Playbooks owner: `7d660cdb4066e2a4cf3fed68bccafea939771e64` (PR #577).
- IaC DNS owner: `ed299ac0cbf0d7f3c355b36f2ecbed794ceebd7f` (PR #396).
- Release: `daily-build-2026.10.06-r2`; environment `uat`; target `web-saas-uat`.
- Parent [37399874543](https://github.com/ai-workspace-infra/platform-ops-toolkit/actions/runs/37399874543): exact baseline child [37399972538](https://github.com/ai-workspace-infra/platform-ops-toolkit/actions/runs/37399972538) captured `absent`, initialization child [37400271339](https://github.com/ai-workspace-infra/platform-ops-toolkit/actions/runs/37400271339) succeeded, and bounded read-only probe child [37400528913](https://github.com/ai-workspace-infra/platform-ops-toolkit/actions/runs/37400528913) succeeded. IaC DNS publication succeeded after host acceptance.

Public verification exposed a third gap: GitOps declared SSH access but omitted
Caddy's public TCP ports. GitOps PR #389 adds only `[80, 443]`, merge
`cd6f28be2fa416f86fa124150df062f4b9d9595e`.
[Plan 37406125053](https://github.com/ai-workspace-infra/platform-ops-toolkit/actions/runs/37406125053)
confirmed `1 add / 0 change / 0 destroy`; [infra apply 37406218452](https://github.com/ai-workspace-infra/platform-ops-toolkit/actions/runs/37406218452)
succeeded. External HTTPS now returns Console Selfhost `200` and Bridge ping
`401`. Parent attempt 2 reruns only the failed public verification, preserving
successful empty-host initialization and child receipts.

## Legacy retirement and scope

The live owner DNS route permits deletion of the old Toolkit reconciler and its
two execution tests. The remaining caller checks assert the immutable IaC pin,
require host acceptance before DNS, and reject restoration of the old executor.
The frozen inventory entry is removed because its file is deleted; other freeze
checksums remain unchanged. The ownership scanner now reports 14 remaining
legacy candidates, down from the original 15-item baseline.

This proves first deployment of an empty UAT database and endpoint readiness.
It does not prove historical subscription preservation, backup/restore rehearsal,
or PROD promotion eligibility. No legacy import or production operation ran.
