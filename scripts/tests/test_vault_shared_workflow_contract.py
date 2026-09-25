import unittest
from pathlib import Path

import yaml


ROOT = Path(__file__).resolve().parents[2]
ENTRY = ROOT / ".github/workflows/vault-server.yml"
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
        self.assertEqual(self.inputs["playbooks_ref"]["default"], "f226989802734f4106d8b6f268b4f02f4eb08a65")

    def test_gateway_tls_is_read_with_the_scoped_xconnect_role_only_when_needed(self):
        steps = steps_by_name(self.jobs["node-stage"]["steps"])
        read = steps["Read the Gateway TLS certificate"]
        self.assertEqual(read["if"], "${{ steps.stage.outputs.needs_tls == 'true' }}")
        self.assertEqual(read["with"]["role"], "${{ needs.declaration.outputs.xconnect_role }}")
        self.assertIs(read["with"]["exportToken"], False)
        paths = {line.split()[0] for line in read["with"]["secrets"].splitlines() if line.strip()}
        self.assertEqual(paths, {"kv/data/CICD/domains/svc.plus"})
        self.assertEqual(
            self.jobs["declaration"]["outputs"]["xconnect_role"],
            "${{ steps.declaration.outputs.xconnect_role }}",
        )
        env = steps["Execute provider-neutral Vault node stage"]["env"]
        self.assertIn("steps.gateway_tls.outputs.VAULT_GATEWAY_TLS_KEY_B64", env["VAULT_GATEWAY_TLS_KEY_B64"])
        self.assertIn("xconnect-gateway-frontend", self.inputs["service_stage"]["options"])

    def test_it_is_a_single_workflow_file(self):
        # The node stage was previously a separate reusable workflow with
        # exactly one caller; that indirection is gone, its jobs are inlined.
        self.assertFalse((ROOT / ".github/workflows/vault-shared-iac.yml").exists())
        self.assertNotIn("uses: ./.github/workflows/vault-shared-iac.yml", ENTRY.read_text(encoding="utf-8"))

    def test_iac_is_optional_and_node_stage_is_gated_on_its_result(self):
        self.assertIn("inputs.deploy_action != 'none'", self.jobs["gcp-shared"]["if"])
        node = self.jobs["node-stage"]
        self.assertEqual(node["runs-on"], "ubuntu-latest")
        self.assertEqual(node["needs"], ["declaration", "gcp-shared"])
        condition = node["if"]
        self.assertIn("always()", condition)
        self.assertIn("needs.declaration.result == 'success'", condition)
        self.assertIn("inputs.deploy_action == 'apply' && needs.gcp-shared.result == 'success'", condition)
        self.assertIn("inputs.deploy_action == 'none' && needs.gcp-shared.result == 'skipped'", condition)
        self.assertIn("github.ref == 'refs/heads/main'", condition)
        self.assertEqual(node["environment"], "${{ needs.declaration.outputs.github_environment }}")

    def test_plan_cannot_be_combined_with_a_node_stage(self):
        guard = steps_by_name(self.jobs["declaration"]["steps"])["Reject dispatch combinations that cannot run"]
        self.assertIn('"${DEPLOY_ACTION}" == plan && "${SERVICE_STAGE}" != none', guard["run"])
        # Stage validation needs the confirm phrase, so it lives in the plan
        # step, not here (without --confirm every gated stage would fail).
        self.assertNotIn("stage_plan.py", guard["run"])
        plan = steps_by_name(self.jobs["declaration"]["steps"])["Resolve the stage plan"]["run"]
        self.assertIn('--confirm "${CONFIRM}"', plan)

    def test_declaration_checks_connection_mode_and_stage_once(self):
        steps = steps_by_name(self.jobs["declaration"]["steps"])
        self.assertIn("stage_plan.py", steps["Resolve the stage plan"]["run"])
        resolve = steps["Resolve environment, Vault paths and connection mode from GitOps"]["run"]
        self.assertIn("resolve_vault_server_declaration.py", resolve)
        self.assertIn('"${declared_mode}" == "${CONNECTION_MODE}"', resolve)
        # Only one call to the resolver script now that declaration is one job.
        self.assertEqual(ENTRY.read_text(encoding="utf-8").count("resolve_vault_server_declaration.py"), 1)


class ProviderNeutralStageTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.workflow = load(ENTRY)
        cls.jobs = cls.workflow["jobs"]
        cls.steps = steps_by_name(cls.jobs["node-stage"]["steps"])

    def test_node_stage_job_shape(self):
        self.assertEqual(self.jobs["node-stage"]["runs-on"], "ubuntu-latest")
        self.assertEqual(self.jobs["node-stage"]["environment"], "${{ needs.declaration.outputs.github_environment }}")

    def test_node_stage_contains_no_cloud_specific_commands(self):
        source = "\n".join(step.get("run", "") for step in self.jobs["node-stage"]["steps"])
        for fragment in ("gcloud", "os-login", "google-github-actions", "open-platform-prod", "0.0.0.0/0"):
            self.assertNotIn(fragment, source)

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
        for field in ("tags", "requires", "confirms", "playbook", "action", "extra_vars", "stage"):
            self.assertEqual(run["with"][field], f"${{{{ steps.stage.outputs.{field} }}}}")
        self.assertIn("steps.stage.outputs.stage != ''", run["if"])
        self.assertIn("steps.stage.outputs.needs_observability == 'true'", self.steps["Read observability ingestion credentials"]["if"])

    def test_stage_is_resolved_after_access_and_auto_mode_can_stop(self):
        names = list(self.steps)
        resolve = self.steps["Resolve the stage to run"]
        self.assertLess(names.index("Verify live SSH host keys against GitOps pins"), names.index("Resolve the stage to run"))
        self.assertLess(names.index("Resolve the stage to run"), names.index("Log in with the stage's scoped Vault role"))
        self.assertIn("auto_migration.py", resolve["run"])
        self.assertIn("stage_plan.py", resolve["run"])
        report = self.steps["Report where migrate-auto stopped"]
        self.assertIn("steps.stage.outputs.blocked != ''", report["if"])
        snapshot = self.steps["Take, encrypt and upload a Raft snapshot"]
        self.assertIn("steps.stage.outputs.snapshot_first == 'true'", snapshot["if"])


class MigrationWiringTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.workflow = load(ENTRY)
        cls.steps = steps_by_name(cls.workflow["jobs"]["node-stage"]["steps"])

    def test_one_run_key_is_shared_by_both_adapters(self):
        self.assertIn("ssh-keygen", self.steps["Create the one-run SSH key"]["run"])
        legacy = self.steps["Open access to the existing vault.svc.plus node"]
        self.assertEqual(legacy["uses"], "./.github/actions/node-access-existing")
        self.assertEqual(legacy["with"]["ssh_key"], self.steps["Open node access through the GCP adapter"]["with"]["ssh_key"])
        self.assertIn("legacy_source.py merge", self.steps["Select the prepared adapters"]["run"])
        self.assertIn("always()", self.steps["Close access to the existing node"]["if"])

    def test_scoped_tokens_and_encrypted_snapshot(self):
        login = self.steps["Log in with the stage's scoped Vault role"]
        self.assertEqual(login["with"]["method"], "jwt")
        self.assertIs(login["with"]["exportToken"], True)
        snapshot = self.steps["Take, encrypt and upload a Raft snapshot"]
        self.assertIn("vault_snapshot.sh", snapshot["run"])
        self.assertIn("age_recipient", snapshot["env"]["BACKUP_AGE_RECIPIENT"])

    def test_existing_node_uses_short_lived_ssh_certificates(self):
        action = load(ROOT / ".github/actions/node-access-existing/action.yml")
        sign = action["runs"]["steps"][0]["run"]
        self.assertIn("audience=vault", sign)
        self.assertIn("auth/jwt/login", sign)
        self.assertIn('ttl:"30m"', sign)
        self.assertIn("::add-mask::", sign)
        self.assertEqual(action["outputs"]["auth_adapter"]["value"], "ssh-certificate")

    def test_new_vault_roles_are_scoped_and_bound_to_the_entry(self):
        policies = ROOT / "scripts/vault/policies"
        self.assertEqual(
            (policies / "github-actions-platform-ops-toolkit-shared-vault-legacy-ssh.hcl").read_text().count("path "), 1
        )
        snapshot = (policies / "github-actions-platform-ops-toolkit-shared-vault-snapshot.hcl").read_text()
        self.assertIn("sys/storage/raft/snapshot", snapshot)
        self.assertNotIn("kv/data/*", snapshot)
        bootstrap = (ROOT / "scripts/vault/bootstrap_shared_gcp_roles.sh").read_text()
        for suffix in ("legacy-ssh", "snapshot", "raft-operator"):
            name = f"github-actions-platform-ops-toolkit-shared-vault-{suffix}"
            self.assertIn(name, bootstrap)
            self.assertIn("vault-server.yml@refs/heads/main", (ROOT / "scripts/vault/roles" / f"{name}.json").read_text())


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
        self.assertIn("os-login ssh-keys remove", steps["Revoke the OS Login key and remove discovery files"]["run"])
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
