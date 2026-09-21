#!/usr/bin/env python3
"""Guard the Akamai workflow against sharing env-level Terraform workdirs."""

from pathlib import Path
import re


ROOT = Path(__file__).resolve().parents[3]
WORKFLOW = ROOT / ".github/workflows/akamai-cloud-iac.yml"
SOURCE = WORKFLOW.read_text(encoding="utf-8")


def require(fragment: str) -> None:
    if fragment not in SOURCE:
        raise AssertionError(f"Akamai workflow is missing required namespace path contract: {fragment}")


require(
    "TF_ROOT: ${{ github.workspace }}/iac_modules/terraform-hcl-standard/akamai-cloud/"
    "envs/${{ inputs.vault_env_path }}/${{ inputs.workspace }}"
)
require('mkdir -p "${TF_ROOT}"')
require('working-directory: ${{ env.TF_ROOT }}')
require('--workdir "${TF_ROOT}"')
require('--namespace "${WORKSPACE}"')
require('terraform -chdir="${TF_ROOT}" init')
require('root="${TF_ROOT}"')
require('terraform -chdir="${root}" validate')
require('terraform -chdir="${root}" plan')
require('terraform -chdir="${TF_ROOT}" "${DEPLOY_ACTION}"')
require("HOSTS_MANIFEST: ${{ env.TF_ROOT }}/hosts_manifest.json")
if SOURCE.count("working-directory: ${{ env.TF_ROOT }}") < 3:
    raise AssertionError("render, destroy guard, and inventory must use the namespace root")
if SOURCE.count('--workdir "${TF_ROOT}"') != 2:
    raise AssertionError("render and inventory must use exactly the shared namespace root")
if SOURCE.count('--namespace "${WORKSPACE}"') != 2:
    raise AssertionError("render and inventory must validate the selected namespace")

if re.search(r'envs/\$\{DEPLOY_ENV\}(?!/\$\{WORKSPACE\})', SOURCE):
    raise AssertionError("Akamai workflow still uses a shared envs/${DEPLOY_ENV} root")
if re.search(r'envs/\$\{\{ inputs\.vault_env_path \}\}(?!/\$\{\{ inputs\.workspace \}\})', SOURCE):
    raise AssertionError("Akamai workflow still uses a shared envs/<environment> root")

print("platform_ops_akamai_namespace_workdir_contract: PASS")
