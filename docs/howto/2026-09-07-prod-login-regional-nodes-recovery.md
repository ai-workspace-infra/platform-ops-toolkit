# PROD login and regional node recovery — 2026-09-07

## Evidence and limits

| Symptom | Verified evidence | Conclusion |
| --- | --- | --- |
| Daily release failed | Daily run `34050510028` dispatched Serverless run `34050718684`; its validation rejected the canonical Console CNAME before deployment. The UAT manifest declares `console-uat.onwalk.net`, while the validator looked up `console.svc.plus` even outside PROD. | Confirmed environment-hardcoding regression in the daily UAT gate; not a PROD runtime failure. |
| US node missing | Selfhost run `34036295720`, job `101495141164`, waited for `admin@35.170.67.199` and timed out. Bootstrap, service deployment and later checks did not run for US. | US deployment is incomplete. The timeout alone does not distinguish expired Spot capacity, stale CMDB, security group, routing or SSH authentication. |
| Serverless login returns to login | Router sends `/api/auth/login` and `/api/auth/session` to Accounts API_AUTH. Accounts source contains session cookie handling; Portal SSR build excludes API routes. | Bypassing Portal BFF alone does NOT prove login failure. Redirecting these routes to the current SSR build would risk 404. |
| CLI probes return HTML challenge | Unauthenticated probes from the debugging machine received Cloudflare challenge responses. | This does not establish what the user's authenticated browser receives. Do not disable WAF globally based on this evidence. |
| Console lacks two regions | US bootstrap failed; actual authenticated node API payload has not been captured. | Neither two-node availability nor a frontend-only rendering defect is established. |

## Implemented repair

Canonical Console DNS validation now selects the hostname by environment. UAT/SIT require their own CNAME; PROD retains its Worker custom-domain requirement (Console alias present, no competing canonical CNAME). Regression tests reject missing/wrong targets and cross-environment records, and run in PR CI.

## Remaining diagnosis and repair plan

1. Capture a real browser login transaction and the immediately following session request. Record status, content type, route/upstream headers and cookie attributes only. Never log passwords, tokens or cookie values. Check whether the browser accepts the session cookie and sends it on `/panel` and `/api/auth/session`.
2. Correlate request IDs across frontend-router, edge auth gateway and Accounts. Verify active deployment SHA and runtime mode. Login and session must use the same production Accounts session store; do not infer live state from local YAML or DNS alone.
3. Distinguish authentication rejection (401/invalid session), authorization denial (403), and dependency failures (5xx/challenge HTML). Portal's session BFF currently clears its cookie on upstream failures, but this only explains the observed loop if that BFF is actually on the live request path.
4. Resolve the US instance from current Terraform/CMDB and AWS API, inspect lifecycle, age, public IP, SSH user and security groups. A one-hour Spot node may have expired before deployment. Do not retry a historical IP blindly or extend the timeout without evidence. Preserve Tokyo and do not modify the legacy node.
5. After US services start, validate dynamic registration in the same PROD Accounts backend used by Console: distinct node IDs, Tokyo/US regions, healthy heartbeat and correct subscription endpoints. Do not fabricate nodes in the UI.

## Release and acceptance

- Merge tested fixes to `main`, generate the next unused `uat-daily-build-YYYY.MM.DD-rN` using the Asia/Shanghai release date, and wait for the required gate. Promote that exact immutable reference to the next unused `vYYYY.MM.DD-rN`; never move an existing tag.
- Set `skip_stripe_catalog=true` for this core-recovery release, retaining all other mandatory gates.
- Accept only after actual browser login persists across reload, both regional nodes appear from the authenticated API, and both perform real user traffic. Grafana API-probe traffic alone is not acceptance.
- Check billing independently: `Xray → Exporter snapshot → Vector → Billing → PostgreSQL → Accounts API → Portal`. Compare per-user deltas and timestamp freshness, excluding internal API probes.
- Roll back through the prior immutable release if needed. Do not delete databases, shared Terraform state, or Tokyo infrastructure as part of login recovery.

## Local verification

```sh
python3 -m unittest discover -s scripts/serverless_uat -p 'test_console_dns_validation.py'
bash .github/scripts/tests/serverless_cloudflare_domains_contract_test.sh
git diff --check
```

This document separates verified causes from remaining hypotheses; it is not a declaration that PROD recovery is complete.
