# 2026-08-03 UAT Agent Proxy Gate: local Ansible hvac dependency

## Symptom

The UAT run using `uat-daily-build-2026.08.03-r6` completed Prepare, Bootstrap,
DB Init, Web SaaS, and Observe, but the Agent Proxy Gate failed in
`deploy_xray_proxy_server.yml` while delegating `community.hashi_vault.vault_write`
to localhost:

> Failed to import the required Python library (hvac) on `/usr/bin/python3`.

## Root cause

The shared installer installed `ansible` and `hvac` through the `pip` command
on the hosted runner. Ansible's delegated localhost execution can use the
runner system interpreter `/usr/bin/python3`, which was a different Python
environment and could not import `hvac`.

## Minimal correction

Keep the existing Ansible installation and additionally install `hvac` through
`python3 -m pip --break-system-packages`, then import-check it before any
playbook runs. This is scoped to the ephemeral GitHub runner; it changes no
UAT or production host and stores no credentials.

## Verification

- `bash -n .github/actions/setup-deployment-runner/scripts/setup.sh`
- `python3 -c 'import hvac'` is performed by the installer itself.
- Rerun the same UAT parameters after merge: r6, 2C4G, `web-saas + agent-proxy`,
  DNS takeover enabled.
