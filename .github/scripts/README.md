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

## Cross-repository delivery contract

The four repositories form one delivery boundary and are changed in dependency order:

1. [`iac_modules`](https://github.com/ai-workspace-infra/iac_modules) — Terraform and
   provision-phase scripts under `scripts/pipeline/`.
2. [`playbooks`](https://github.com/ai-workspace-infra/playbooks) — Ansible-phase scripts
   under `scripts/pipeline/`.
3. [`gitops`](https://github.com/ai-workspace-infra/gitops) — YAML/Markdown desired-state
   data only; it must not contain deployment scripts.
4. `platform-ops-toolkit` — orchestration, dispatch, wait, snapshot, serverless,
   API-based DNS, SSH observation, and GitOps readers.

For a cross-repository change, merge the `iac_modules` and `playbooks` additions first,
then update the toolkit call sites. The toolkit PR description records the dependency PRs
and merge order. GitOps declarations are consumed by ref; they are not copied into any
workflow or script.

New scripts use short-hyphen names, have a test under the owning directory's `tests/`,
and are mode `100755` when called directly. Do not add one-line forwarding wrappers or
compatibility shims. Composite actions remain in `.github/actions/`; sourced helpers remain
in the owning repository's `lib/`. The three code repositories keep byte-identical
`require-env.sh` copies so a pinned checkout never reaches into another repository.

Branch changes are PR-only and use the repository's existing `feature/`, `bugfix/`,
`hotfix/`, or equivalent prefix. After merge, delete the head branch; long-lived branches
are limited to `main` and `release/*` (with `stable/*` retained where the repository
already uses it). See the branch-policy skill in each repository for release-specific rules.
