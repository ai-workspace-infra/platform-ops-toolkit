import unittest
from pathlib import Path

import yaml


ROOT = Path(__file__).resolve().parents[2]
OWNER_SHA = "d7e49189a5de9c105a940f1c79abfb3b2b33bbd4"
CONFIGURE = ROOT / ".github/actions/configure-gcp-oidc/action.yml"
IDENTITY = ROOT / ".github/actions/load-gcp-cloud-identity/action.yml"
AUTH_CALLERS = (
    "selfhost-orchestrator.yml",
    "ai-aggregator-v1.yml",
    "observability-server.yml",
    "zitadel-server.yml",
)


def load(path: Path):
    return yaml.safe_load(path.read_text(encoding="utf-8"))


class GcpAuthenticationOwnerRoutingTests(unittest.TestCase):
    def test_configure_contract_is_preserved_while_exchange_moves_to_iac(self):
        action = load(CONFIGURE)
        self.assertEqual(
            set(action["inputs"]),
            {"environment", "credential_environment", "account_id", "vault_addr", "vault_role", "load_state_contract"},
        )
        self.assertEqual(
            set(action["outputs"]),
            {"project_id", "provider", "service_account", "state_endpoint", "state_bucket", "state_access_key", "state_secret_key", "state_region"},
        )
        steps = action["runs"]["steps"]
        self.assertEqual(steps[0]["uses"], "./.github/actions/load-gcp-cloud-identity")
        self.assertEqual(steps[1]["uses"], "./iac_modules/.github/actions/auth-gcp-cloud")
        self.assertEqual(steps[1]["with"]["load-state-contract"], "${{ inputs.load_state_contract }}")
        self.assertNotIn("google-github-actions/auth", CONFIGURE.read_text(encoding="utf-8"))

        identity = load(IDENTITY)
        identity_source = IDENTITY.read_text(encoding="utf-8")
        self.assertEqual(len(identity["runs"]["steps"]), 2)
        self.assertIn("credential_environment || inputs.environment", identity_source)
        self.assertIn("inputs.vault_role || format", identity_source)
        self.assertNotIn("google-github-actions", identity_source)
        self.assertNotIn("gcloud", identity_source)

    def test_all_nine_callers_checkout_the_exact_owner_before_authentication(self):
        caller_count = 0
        for filename in AUTH_CALLERS:
            workflow = load(ROOT / ".github/workflows" / filename)
            for job_name, job in workflow["jobs"].items():
                if not isinstance(job, dict):
                    continue
                steps = job.get("steps", [])
                for index, step in enumerate(steps):
                    if step.get("uses") != "./.github/actions/configure-gcp-oidc":
                        continue
                    caller_count += 1
                    owners = [
                        candidate
                        for candidate in steps[:index]
                        if candidate.get("uses", "").startswith("actions/checkout@")
                        and candidate.get("with", {}).get("repository") == "ai-workspace-infra/iac_modules"
                        and candidate.get("with", {}).get("path") == "iac_modules"
                    ]
                    self.assertTrue(owners, f"{filename}:{job_name} has no IaC owner checkout")
                    owner = owners[-1]
                    self.assertEqual(owner["with"]["ref"], OWNER_SHA, f"{filename}:{job_name}")
                    sparse = owner["with"].get("sparse-checkout", "")
                    if sparse:
                        self.assertIn(".github/actions/auth-gcp-cloud", sparse, f"{filename}:{job_name}")
        self.assertEqual(caller_count, 9)


class GcpNodeAccessOwnerRoutingTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.workflow = load(ROOT / ".github/workflows/vault-server.yml")

    def test_six_cloud_calls_use_the_fixed_iac_owner_and_explicit_identity(self):
        calls = []
        legacy_calls = []
        for job in self.workflow["jobs"].values():
            if not isinstance(job, dict):
                continue
            for step in job.get("steps", []):
                if step.get("uses") == "./iac_modules/.github/actions/node-access-gcp":
                    calls.append(step)
                if step.get("uses") == "./.github/actions/node-access-gcp":
                    legacy_calls.append(step)
        self.assertEqual(len(calls), 6)
        self.assertEqual(legacy_calls, [])
        for step in calls:
            for field in ("identity_provider", "service_account", "audience", "credential_project_id"):
                self.assertIn(field, step["with"])
                self.assertIn("_identity.outputs", step["with"][field])

    def test_node_and_cleanup_jobs_checkout_the_same_owner_commit(self):
        self.assertEqual(self.workflow[True]["workflow_dispatch"]["inputs"]["iac_ref"]["default"], OWNER_SHA)
        for job_name in ("node-stage", "cleanup-node-access"):
            checkouts = [
                step for step in self.workflow["jobs"][job_name]["steps"]
                if step.get("with", {}).get("repository") == "ai-workspace-infra/iac_modules"
            ]
            self.assertEqual(len(checkouts), 1, job_name)
            checkout = checkouts[0]
            self.assertEqual(checkout["with"]["ref"], "${{ inputs.iac_ref }}")
            for path in (".github/actions/auth-gcp-cloud", ".github/actions/node-access-gcp", "scripts/node_deploy", "scripts/pipeline"):
                self.assertIn(path, checkout["with"]["sparse-checkout"])

    def test_vault_selection_stays_in_toolkit_and_cleanup_stays_fail_closed(self):
        source = (ROOT / ".github/workflows/vault-server.yml").read_text(encoding="utf-8")
        self.assertEqual(source.count("uses: ./.github/actions/load-gcp-cloud-identity"), 4)
        node_steps = {step["name"]: step for step in self.workflow["jobs"]["node-stage"]["steps"]}
        for name in ("Close access to the GCP migration source", "Close node access through the GCP adapter"):
            self.assertIn("always()", node_steps[name]["if"])
        cleanup = self.workflow["jobs"]["cleanup-node-access"]
        self.assertIn("always()", cleanup["if"])
        self.assertIn("needs.node-stage.result != 'skipped'", cleanup["if"])


if __name__ == "__main__":
    unittest.main()
