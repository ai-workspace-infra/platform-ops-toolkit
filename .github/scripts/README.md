# .github/scripts

Scripts called by the workflows in this repository. A pipeline step lives in the
repository that owns the thing it operates on:

| The step… | Lives in | Called as |
|-----------|----------|-----------|
| runs `terraform`, or is part of the provision phase inside the IaC checkout | `iac_modules/scripts/pipeline/` | `${{ github.workspace }}/infra/iac_modules/scripts/pipeline/<name>` (or `iac_modules/…`, matching the job's checkout `path`) |
| runs `ansible` / `ansible-playbook` inside the playbooks checkout | `playbooks/scripts/pipeline/` | `${{ github.workspace }}/playbooks/scripts/pipeline/<name>` |
| orchestrates: routing, dispatch and wait, immutable snapshots, sanitized receipts, reading GitOps data | here | `${{ github.workspace }}/.github/scripts/<area>/<name>` |
| changes a host, deploys services, exports/restores a database, or executes reviewed SQL | `playbooks` reusable roles | pinned owner workflow called by `environment-data-operations.yml` |
| executes provider/state changes or creates storage/network resources | `iac_modules` | pinned provider execution workflow; GitOps holds only desired state |

`gitops` stays data only: the scripts that read or validate it are in `gitops/` below.

| Directory | Contents |
|-----------|----------|
| `lib/` | sourced helpers: `require-env.sh` (`require_env`), `cmdb-ssh-login.sh` |
| `gitops/` | readers and validators for GitOps manifests and routing config |
| `platform-ops/` | selfhost orchestration: `provision/` (routing, dispatch, OIDC, key derivation), `deploy/`, `dns/`, `observe/` |
| `environment-upgrade/` | data-operation dispatch and release evidence validation only |
| `snapshots/`, `release/` | immutable artifact/tag orchestration |
| `serverless/`, `resize/`, `platform-ops/`, … | mixed-generation legacy areas; execution files are migration debt, not an approved boundary |
| `tests/` | contract tests owned by the relevant workflow or repository |

Composite actions stay in `.github/actions/` of this repository: `uses: ./…` resolves
against the workspace, and some pipelines pin `iac_modules` to a fixed SHA.

## Guards

`platform-ops-toolkit` is a control-plane repository. Its release PR validation
is limited to the sensitive-information scan and immutable TAG/ref rules. Product
business checks, database checks, host health checks, and deployment acceptance
run in the owning service, Playbooks, IaC, or GitOps flow; they must not be added
to `validate-release-pr.yml` or duplicated under `.github/scripts/`.

The former release-PR business and infrastructure contract-test bundle was
removed when its callers were retired. The active owner checklist now lives in
[`playbooks/docs/checklists/platform-ops-presetup-postsetup.md`](https://github.com/ai-workspace-infra/playbooks/blob/main/docs/checklists/platform-ops-presetup-postsetup.md).

- `scripts/ci/workflow_script_refs_verify.py` — every script a workflow calls exists,
  and a call into `iac_modules` / `playbooks` is preceded by that checkout in the same job.
- `scripts/ci/workflow_gating_verify.py` — job gating, and the exec bit of scripts called bare.
- `scripts/ci/script_exec_bit_verify.sh` — every tracked `*.sh` is mode 100755.
- `scripts/ci/script_ownership_verify.py` — rejects new execution logic or changes to frozen legacy execution copies; deletion is allowed after callers migrate.

`scripts/ci/legacy-execution-inventory.json` records existing migration debt by
owner and checksum. It is not a claim that those files are control-plane-only,
nor a license to add another exception. CI locks each legacy copy; behavior
changes must first migrate to Playbooks/IaC with caller, Vault, tests and docs
updated. Never put imperative execution in GitOps. The obsolete, unreferenced
Supabase initialization wrapper has been removed rather than preserved as a
hidden schema reset path.

Observability's combined DNS/host executor has been removed. The workflow now
calls the pinned IaC Modules Cloudflare record transaction, then the Playbooks
`observability_server_operations` Role for Caddy refresh and HTTPS acceptance.
Toolkit requests checkpoint recovery on acceptance failure without masking the
failed run. Observability data migration and service checks also belong to the
Playbooks Role, not a Toolkit copy or a GitOps executor.

A workflow that pins `infra_ref` / `playbooks_ref` to a tag older than the
`scripts/pipeline/` directories will not find these scripts; pin to a ref that has them.

## Cross-repository delivery contract

Caddy PEM restoration now calls the immutable Playbooks
`caddy_certificate_restore.yml` owner. Toolkit's
`prepare-domain-tls-restore.py` only exchanges OIDC/Vault identity and writes a
mode-0600 runtime vars file; the workflow invokes the Role using this run's CMDB
or explicit non-IaC inventory and always removes the vars file. Vault tokens are
revoked before host execution. The legacy executor stays until caller and UAT
verification; no Caddy restart or served-TLS claim is added by this cutover.

The four repositories form one delivery boundary and are changed in dependency order:

1. [`iac_modules`](https://github.com/ai-workspace-infra/iac_modules) — Terraform and
   provision-phase scripts under `scripts/pipeline/`.
2. [`playbooks`](https://github.com/ai-workspace-infra/playbooks) — Ansible-phase scripts
   under `scripts/pipeline/`.
3. [`gitops`](https://github.com/ai-workspace-infra/gitops) — YAML/Markdown desired-state
   data only; it must not contain deployment scripts.
4. `platform-ops-toolkit` — orchestration, dispatch, wait, immutable snapshots,
   receipt validation, and GitOps readers. Provider API writes and host probes
   belong to the resource/execution owner, even when a legacy copy remains.

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
