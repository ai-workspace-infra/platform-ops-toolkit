#!/usr/bin/env python3
"""Protect Vault scope, caller ref and DB Init semantics during deduplication."""
import unittest
from pathlib import Path
import yaml

ROOT = Path(__file__).resolve().parents[3]
JOBS = ("capture_web_saas_baseline", "accept_web_saas_upgrade", "initialize_web_saas_databases")


def validate(action, workflow):
    steps = action["runs"]["steps"]
    assert [step["uses"] for step in steps] == [
        "actions/download-artifact@v8", "hashicorp/vault-action@v4", "./.github/actions/setup-deployment-runner"]
    assert steps[0]["with"] == {"name": "platform-ops-toolkit-cmdb", "path": "cmdb"}
    auth = steps[1]["with"]
    assert auth["method"] == "jwt" and auth["jwtGithubAudience"] == "vault"
    assert auth["url"] == "${{ inputs.vault_address }}" and auth["role"] == "${{ inputs.vault_role }}"
    assert "${{ inputs.vault_kv_path }} SSH_PRIVATE_DEPLOY_KEY_B64" in auth["secrets"]
    assert "inputs.root_bootstrap_vault_path && format" in auth["secrets"]
    assert "ignoreNotFound" not in auth, "missing required secrets must still fail"
    assert set(action["outputs"]) == {"ROOT_BOOTSTRAP_PASSWORD"}, "do not expose the SSH private key"
    runner = steps[2]["with"]
    assert runner["cmdb_file"] == "cmdb/cmdb.json" and runner["wait_for_ssh"] == "true"
    assert runner["ssh_key_b64"] == "${{ steps.vault.outputs.ANSIBLE_SSH_KEY_B64 }}"
    assert action["inputs"]["export_vault_token"]["default"] == "false"
    assert workflow["permissions"]["id-token"] == "write"
    for name in JOBS:
        job = workflow["jobs"][name]
        callers = [step for step in job["steps"] if step.get("uses") == "./.github/actions/prepare-host-runner"]
        assert len(callers) == 1
        caller = callers[0]
        # Local actions resolve from the workspace checkout. These three jobs
        # already use github.sha; leave jobs with an older toolkit_ref alone.
        root_checkout = next(step for step in job["steps"] if step.get("uses", "").startswith("actions/checkout@")
                             and not step.get("with", {}).get("path"))
        assert root_checkout["with"]["ref"] == "${{ github.sha }}"
        assert job["steps"].index(root_checkout) < job["steps"].index(caller)
        assert caller["id"] == "vault"
        options = caller["with"]
        assert options["vault_address"] == "${{ env.VAULT_ADDR }}"
        assert options["vault_role"] == "${{ env.VAULT_ROLE }}"
        assert options["vault_kv_path"] == "${{ env.VAULT_KV_BASE }}"
        assert options["matrix_host"] == "${{ matrix.host }}"
        if name == "initialize_web_saas_databases":
            assert options["root_bootstrap_vault_path"] == "${{ env.VAULT_KV }}"
            assert options["export_vault_token"] == "true"
            assert options["install_ansible"] == options["assert_ansible_target"] == "true"
            assert options["ansible_inventory"] == "cmdb/inventory.ini"
            probe = next(i for i, step in enumerate(job["steps"]) if step.get("name") == "Wait for Doco-CD Web SaaS PostgreSQL readiness")
            assert job["steps"].index(caller) < probe
        else:
            assert "root_bootstrap_vault_path" not in options and "export_vault_token" not in options


class HostRunnerContractTests(unittest.TestCase):
    def setUp(self):
        self.action = yaml.safe_load((ROOT / ".github/actions/prepare-host-runner/action.yml").read_text())
        self.workflow = yaml.safe_load((ROOT / ".github/workflows/selfhost-orchestrator.yml").read_text())

    def test_current_contract(self):
        validate(self.action, self.workflow)

    def test_deployment_tag_checkout_would_break_local_action(self):
        self.workflow["jobs"][JOBS[0]]["steps"][0]["with"]["ref"] = "${{ needs.provision.outputs.toolkit_ref }}"
        with self.assertRaises(AssertionError):
            validate(self.action, self.workflow)

    def test_missing_secret_cannot_be_ignored(self):
        self.action["runs"]["steps"][1]["with"]["ignoreNotFound"] = True
        with self.assertRaises(AssertionError):
            validate(self.action, self.workflow)

    def test_no_ssh_key_output(self):
        self.action["outputs"]["SSH_PRIVATE_KEY"] = {"value": "${{ steps.vault.outputs.ANSIBLE_SSH_KEY_B64 }}"}
        with self.assertRaises(AssertionError):
            validate(self.action, self.workflow)

    def test_cmdb_must_not_come_from_another_run(self):
        self.action["runs"]["steps"][0]["with"]["run-id"] = "1234"
        with self.assertRaises(AssertionError):
            validate(self.action, self.workflow)


if __name__ == "__main__":
    unittest.main()
