"""Cover event selectors, resource templates and deployment preflight gates."""

import copy
from pathlib import Path
import tempfile
import unittest

import yaml

from resolve_ai_aggregator_deployment import materialize, resolve


ROOT = Path(__file__).resolve().parents[2]


class DeploymentTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.template = {
            "kind": "PersonalAIAggregator",
            "metadata": {"environment": "preview", "topology": "single-node"},
            "spec": {
                "enabled": False,
                "infrastructure": {
                    # Legacy selection fields must not override event inputs.
                    "provider": "aws", "lifecycle": "ephemeral",
                    "resource_contract": {"renderer": "terraform-hcl-standard/gcp-cloud/scripts/generate.py"},
                },
                "nodes": [{"provider": "aws"}],
                "testing_environment": {"provider": "aws"},
            },
        }
        self.write(self.template)

    def write(self, data, filename="ai-aggregator.yaml"):
        path = self.root / "topology" / data["metadata"]["environment"] / "selfhost" / filename
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(yaml.safe_dump(data))
        return path

    def select(self, environment="preview", provider="gcp", operation="plan"):
        return resolve(self.root, environment, "single-node", provider, operation)

    def test_event_input_selects_cloud_independently_of_legacy_provider(self):
        outputs = self.select()
        self.assertEqual(outputs["provider"], "gcp")
        self.assertEqual(outputs["environment"], "preview")
        original = Path(outputs["template_path"]).read_text()
        materialize(outputs)
        rendered = yaml.safe_load(Path(outputs["manifest_path"]).read_text())
        self.assertEqual(rendered["spec"]["infrastructure"]["provider"], "gcp")
        self.assertEqual(rendered["spec"]["nodes"][0]["provider"], "gcp")
        self.assertEqual(rendered["spec"]["testing_environment"]["provider"], "gcp")
        self.assertEqual(Path(outputs["template_path"]).read_text(), original)

    def test_input_selects_other_resource_formats(self):
        for provider, renderer in (
            ("aws", "terraform-hcl-standard/aws-cloud/scripts/generate.py"),
            ("vps", "terraform-hcl-standard/vultr-cloud/scripts/generate.py"),
            ("existing", "cmdb/inventory"),
        ):
            with self.subTest(provider=provider):
                template = copy.deepcopy(self.template)
                template["spec"]["infrastructure"]["resource_contract"]["renderer"] = renderer
                self.write(template, f"ai-aggregator-{provider}.yaml")
                self.assertEqual(self.select(provider=provider)["provider"], provider)

    def test_environment_input_selects_its_own_template(self):
        template = copy.deepcopy(self.template)
        template["metadata"]["environment"] = "production-eu"
        self.write(template)
        outputs = self.select(environment="production-eu")
        self.assertIn("topology/production-eu/", outputs["template_path"])
        self.assertEqual(outputs["environment"], "production-eu")

    def test_missing_resource_format_cannot_fall_back_to_another_cloud(self):
        with self.assertRaisesRegex(ValueError, "found 0"):
            self.select(provider="vps")

    def test_missing_environment_cannot_fall_back_to_another_environment(self):
        with self.assertRaisesRegex(ValueError, "found 0"):
            self.select(environment="staging")

    def test_disabled_stage_and_activate_fail_before_materialization(self):
        for operation in ("stage", "activate"):
            with self.subTest(operation=operation):
                with self.assertRaisesRegex(ValueError, "no resources will be created"):
                    self.select(operation=operation)
        self.assertFalse((self.root / ".runtime").exists())

    def test_disabled_plan_and_provision_remain_available(self):
        for operation in ("plan", "apply", "provision"):
            self.assertEqual(self.select(operation=operation)["deployment_enabled"], "false")

    def test_yaml_boolean_is_independent_of_indentation(self):
        template = copy.deepcopy(self.template)
        template["spec"]["enabled"] = True
        path = self.write(template)
        path.write_text(yaml.safe_dump(template, indent=4))
        self.assertEqual(self.select(operation="activate")["deployment_enabled"], "true")
        template["spec"]["enabled"] = "false"
        self.write(template)
        with self.assertRaisesRegex(ValueError, "YAML boolean"):
            self.select(operation="activate")

    def test_environment_cannot_escape_namespace(self):
        for environment in ("../prod", "prod\nprovider=aws", "", "UAT"):
            with self.subTest(environment=environment):
                with self.assertRaisesRegex(ValueError, "lowercase name"):
                    self.select(environment=environment)

    def test_ambiguous_declarations_are_rejected(self):
        self.write(self.template, "ai-aggregator-copy.yaml")
        with self.assertRaisesRegex(ValueError, "found 2"):
            self.select()

    def test_existing_nodes_cannot_be_provisioned(self):
        self.template["spec"]["infrastructure"]["resource_contract"]["renderer"] = "cmdb/inventory"
        self.write(self.template)
        with self.assertRaisesRegex(ValueError, "existing nodes support"):
            self.select(provider="existing", operation="apply")

    def test_akamai_paths_and_state_follow_input_environment(self):
        infrastructure = self.template["spec"]["infrastructure"]
        infrastructure["resource_contract"] = {
            "renderer": "terraform-hcl-standard/akamai-cloud/scripts/generate.py",
            "workdir": "terraform-hcl-standard/akamai-cloud/envs/preview/gateway",
            "account": "lab-account",
            "manifests": [{"path": "resources/example.net/preview/akamai/gateway.yaml", "workspace": "gateway"}],
        }
        self.write(self.template)
        outputs = self.select(provider="akamai-cloud")
        self.assertIn("terraform/preview/example.net/akamai-cloud/lab-account/gateway/terraform.tfstate", outputs["akamai_matrix"])
        infrastructure["resource_contract"]["manifests"][0]["path"] = "resources/example.net/other/akamai/gateway.yaml"
        self.write(self.template)
        with self.assertRaisesRegex(ValueError, "selected environment"):
            self.select(provider="akamai-cloud")


class WorkflowTests(unittest.TestCase):
    def test_mutations_require_plan_and_use_event_provider(self):
        workflow = yaml.safe_load((ROOT / ".github/workflows/ai-aggregator-v1.yml").read_text())
        for provider, job in (("aws", "aws-deploy"), ("gcp", "gcp-deploy"), ("vps", "vps-deploy"),
                              ("akamai-cloud", "akamai-deploy"), ("existing", "existing-deploy")):
            with self.subTest(job=job):
                declaration = workflow["jobs"][job]
                self.assertIn("plan", declaration["needs"])
                self.assertIn("github.event_name == 'workflow_dispatch'", declaration["if"])
                self.assertIn(f"outputs.provider == '{provider}'", declaration["if"])
                self.assertNotIn("outputs.deployment_environment", declaration["if"])


if __name__ == "__main__":
    unittest.main()
