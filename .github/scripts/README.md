# .github/scripts

Scripts called by the workflows in this repository. A pipeline step lives in the
repository that owns the thing it operates on:

| The step… | Lives in | Called as |
|-----------|----------|-----------|
| runs `terraform`, or is part of the provision phase inside the IaC checkout | `iac_modules/scripts/pipeline/` | `${{ github.workspace }}/infra/iac_modules/scripts/pipeline/<name>` (or `iac_modules/…`, matching the job's checkout `path`) |
| runs `ansible` / `ansible-playbook` inside the playbooks checkout | `playbooks/scripts/pipeline/` | `${{ github.workspace }}/playbooks/scripts/pipeline/<name>` |
| orchestrates: routing, dispatch and wait, snapshots, serverless, DNS through an API, SSH observers, reading GitOps data | here | `${{ github.workspace }}/.github/scripts/<area>/<name>` |

`gitops` stays data only: the scripts that read or validate it are in `gitops/` below.

| Directory | Contents |
|-----------|----------|
| `lib/` | sourced helpers: `require-env.sh` (`require_env`), `cmdb-ssh-login.sh` |
| `gitops/` | readers and validators for GitOps manifests and routing config |
| `platform-ops/` | selfhost orchestration: `provision/` (routing, dispatch, OIDC, key derivation), `deploy/`, `dns/`, `observe/` |
| `serverless/`, `snapshots/`, `data-migration/`, `resize/`, `release/`, … | one directory per workflow family |
| `tests/` | contract tests; run by `validate-release-pr.yml` |

Composite actions stay in `.github/actions/` of this repository: `uses: ./…` resolves
against the workspace, and some pipelines pin `iac_modules` to a fixed SHA.

## Guards

- `scripts/ci/workflow_script_refs_verify.py` — every script a workflow calls exists,
  and a call into `iac_modules` / `playbooks` is preceded by that checkout in the same job.
- `scripts/ci/workflow_gating_verify.py` — job gating, and the exec bit of scripts called bare.
- `scripts/ci/script_exec_bit_verify.sh` — every tracked `*.sh` is mode 100755.

A workflow that pins `infra_ref` / `playbooks_ref` to a tag older than the
`scripts/pipeline/` directories will not find these scripts; pin to a ref that has them.
