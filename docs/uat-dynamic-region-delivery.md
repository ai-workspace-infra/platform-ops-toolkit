# UAT dynamic regional-entry delivery

## Environment contract

| Environment | Public Accounts | Public Billing |
| --- | --- | --- |
| UAT | `https://accounts-uat.onwalk.net` | `https://billing-uat.onwalk.net` |
| PROD | `https://accounts.svc.plus` | `https://billing.svc.plus` |

Public service contracts are declared in `config/iac_environment_defaults.json`.
Machine origins come from the selected environment GitOps topology, with an
explicit environment check. Agent machine requests use `/api/agent-server/v1/users`;
`/nodes` requires a user session and is not a bearer-token deployment preflight.
Production release refs and Vault OIDC roles remain isolated from UAT.

## Delivery and acceptance

1. PR → main → immutable snapshot → UAT Serverless deployment. Reconcile the
   canonical UAT Accounts custom domain with `dns_mode=uat-records`. Billing is
   bound to the core gateway using its canonical host; never point it at the
   frontend router or infer its origin from Accounts host prefixes.
2. GitOps host variables declare `xconnect_region`, `xconnect_pool`,
   `xconnect_fqdn`, and `xconnect_open_to_users`. Terraform runtime facts and
   those variables must both survive CMDB/inventory generation. Ansible renders
   the same values as `region`, `pool`, `entryPoint`, and `openToUsers` in
   `/etc/agent/account-agent.yaml`; credentials stay in Vault.
3. New or unverified entries remain explicitly closed. Run **UAT Regional Entry
   Acceptance** for the agent-reported entry. It checks trusted public TLS on
   TCP 443 and 1443 from a GitHub runner and records a report. Listener readiness
   does not prove an authenticated VLESS session.
4. After the listener gate passes, open the declared node via PR and deploy the
   configuration. Require a fresh real agent heartbeat, the matching open
   regional-pools row, and the same region in `/panel`, including its subscription
   QR code. Verify a real client connection before claiming end-to-end acceptance.
5. Do not create replacement JP/US instances or include existing production TW
   proxy traffic merely to update SG metadata. No production cutover is implied.

A closed region intentionally has no user subscription URI or QR code. The panel
must explain this availability state rather than leave an unexplained dash.
