import unittest
from pathlib import Path

import yaml


ROOT = Path(__file__).resolve().parents[2]
ENTRY = ROOT / ".github/workflows/vault-server.yml"
GENERIC = ROOT / ".github/workflows/vault-shared-iac.yml"
GCP_ADAPTER = ROOT / ".github/actions/node-access-gcp/action.yml"
NODE_STAGE = ROOT / ".github/actions/vault-node-stage/action.yml"


def load(path):
    return yaml.safe_load(path.read_text(encoding="utf-8"))


def steps_by_name(steps):
    return {step["name"]: step for step in steps}


class VaultServerEntryTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.workflow = load(ENTRY)
        cls.inputs = cls.workflow[True]["workflow_dispatch"]["inputs"]
        cls.jobs = cls.workflow["jobs"]

    def test_renamed_entry_keeps_one_stage_per_dispatch(self):
        self.assertFalse((ROOT / ".github/workflows/vault-shared-gcp-iac.yml").exists())
        self.assertEqual(self.inputs["deploy_action"]["options"], ["none", "plan", "apply"])
        self.assertEqual(self.inputs["connection_mode"]["options"], ["bootstrap-public"])
        self.assertNotIn("xconnect-gateway", self.inputs["service_stage"]["options"])
        self.assertEqual(self.inputs["playbooks_ref"]["default"], "7affb1d53001a248c1266ca747f8ba22980281aa")

    def test_iac_is_optional_and_node_stage_is_gated_on_its_result(self):
        self.assertIn("inputs.deploy_action != 'none'", self.jobs["gcp-shared"]["if"])
        node = self.jobs["node-stage"]
        self.assertEqual(node["uses"], "./.github/workflows/vault-shared-iac.yml")
        self.assertEqual(node["needs"], ["declaration", "gcp-shared"])
        condition = node["if"]
        self.assertIn("always()", condition)
        self.assertIn("needs.declaration.result == 'success'", condition)
        self.assertIn("inputs.deploy_action == 'apply' && needs.gcp-shared.result == 'success'", condition)
        self.assertIn("inputs.deploy_action == 'none' && needs.gcp-shared.result == 'skipped'", condition)
        self.assertIn("github.ref == 'refs/heads/main'", condition)
        self.assertEqual(node["with"]["provider"], "${{ inputs.cloud_provider }}")

    def test_plan_cannot_be_combined_with_a_node_stage(self):
        guard = steps_by_name(self.jobs["declaration"]["steps"])["Reject dispatch combinations that cannot run"]
        self.assertIn('"${DEPLOY_ACTION}" == plan && "${SERVICE_STAGE}" != none', guard["run"])
        self.assertIn("stage_plan.py", guard["run"])

    def test_entry_has_no_cloud_login_or_ssh_logic(self):
        source = ENTRY.read_text(encoding="utf-8")
        for fragment in ("gcloud", "os-login", "firewall-rules", "vault-action", "open-platform-prod"):
            self.assertNotIn(fragment, source)


class ProviderNeutralStageTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.workflow = load(GENERIC)
        cls.jobs = cls.workflow["jobs"]
        cls.steps = steps_by_name(cls.jobs["node-stage"]["steps"])

    def test_reusable_contract(self):
        inputs = self.workflow[True]["workflow_call"]["inputs"]
        self.assertEqual(
            set(inputs),
            {"stage", "provider", "service_manifest", "provider_manifest", "connection_mode", "gitops_repo_ref", "playbooks_ref"},
        )
        self.assertEqual(self.jobs["node-stage"]["runs-on"], "ubuntu-latest")
        self.assertEqual(self.jobs["node-stage"]["environment"], "${{ needs.declaration.outputs.github_environment }}")

    def test_generic_workflow_contains_no_cloud_specific_commands(self):
        source = GENERIC.read_text(encoding="utf-8")
        for fragment in ("gcloud", "os-login", "google-github-actions", "open-platform-prod", "0.0.0.0/0"):
            self.assertNotIn(fragment, source)

    def test_declaration_checks_connection_mode_and_stage(self):
        steps = steps_by_name(self.jobs["declaration"]["steps"])
        self.assertIn("stage_plan.py", steps["Resolve the stage plan"]["run"])
        resolve = steps["Resolve environment, Vault paths and connection mode from GitOps"]["run"]
        self.assertIn("resolve_vault_server_declaration.py", resolve)
        self.assertIn('"${declared_mode}" == "${CONNECTION_MODE}"', resolve)

    def test_adapter_opens_and_closes_access_and_host_keys_are_pinned(self):
        open_step = self.steps["Open node access through the GCP adapter"]
        self.assertEqual(open_step["uses"], "./.github/actions/node-access-gcp")
        self.assertEqual(open_step["with"]["phase"], "open")
        close_step = self.steps["Close node access through the GCP adapter"]
        self.assertEqual(close_step["with"]["phase"], "close")
        self.assertIn("always()", close_step["if"])
        self.assertIn("prepare_known_hosts.py", self.steps["Verify live SSH host keys against GitOps pins"]["run"])
        cleanup = self.jobs["cleanup-node-access"]
        self.assertIn("always()", cleanup["if"])
        self.assertIn("needs.node-stage.result != 'skipped'", cleanup["if"])
        self.assertEqual(cleanup["steps"][-1]["with"]["phase"], "close")

    def test_stage_runner_receives_plan_outputs(self):
        run = self.steps["Execute provider-neutral Vault node stage"]
        self.assertEqual(run["uses"], "./.github/actions/vault-node-stage")
        for field in ("tags", "requires", "confirms", "playbook"):
            self.assertEqual(run["with"][field], f"${{{{ needs.declaration.outputs.{field} }}}}")
        self.assertIn("needs_observability == 'true'", self.steps["Read observability ingestion credentials"]["if"])


class AdapterAndRunnerTests(unittest.TestCase):
    def test_gcp_adapter_uses_short_lived_identities_and_cleans_up(self):
        action = load(GCP_ADAPTER)
        steps = steps_by_name(action["runs"]["steps"])
        self.assertEqual(steps["Read GCP runtime identity with the scoped Vault JWT role"]["with"]["method"], "jwt")
        self.assertIn("--ttl=65m", steps["Prepare one-run OS Login SSH identity"]["run"])
        resolve = steps["Resolve live GCP nodes and the private Raft channel into a NodeDeployment"]["run"]
        self.assertIn("firewall-rules list", resolve)
        self.assertIn("--firewalls", resolve)
        create = steps["Temporarily open SSH for the bootstrap job"]
        self.assertIn("--source-ranges=0.0.0.0/0", create["run"])
        self.assertIn("--rules=tcp:22", create["run"])
        self.assertIn("inputs.connection_mode == 'bootstrap-public'", create["if"])
        self.assertIn("firewall-rules delete", steps["Delete and verify the temporary public SSH rule"]["run"])
        self.assertIn("os-login ssh-keys remove", steps["Revoke the OS Login key and remove local key material"]["run"])
        self.assertEqual(action["outputs"]["auth_adapter"]["value"], "gcp-oslogin-ephemeral")

    def test_node_stage_gates_before_and_after_the_playbook(self):
        action = load(NODE_STAGE)
        steps = action["runs"]["steps"]
        names = [step["name"] for step in steps]
        before = names.index("Check live node state required by the stage")
        apply = names.index("Apply the stage playbook tags")
        after = names.index("Confirm live node state after the stage")
        self.assertLess(before, apply)
        self.assertLess(apply, after)
        source = NODE_STAGE.read_text(encoding="utf-8")
        self.assertIn("StrictHostKeyChecking=yes", source)
        self.assertIn("verify_vault_stage.py", steps[before]["run"])
        self.assertIn("run_stage.sh", steps[apply]["run"])
        self.assertNotIn("VAULT_TOKEN", source)

    def test_vault_roles_bind_the_entry_workflow(self):
        for role in ("node-oidc-open-platform-prod", "monitoring", "xconnect"):
            path = ROOT / "scripts/vault/roles" / f"github-actions-platform-ops-toolkit-shared-vault-{role}.json"
            self.assertIn(".github/workflows/vault-server.yml@refs/heads/main", path.read_text(encoding="utf-8"))


if __name__ == "__main__":
    unittest.main()
