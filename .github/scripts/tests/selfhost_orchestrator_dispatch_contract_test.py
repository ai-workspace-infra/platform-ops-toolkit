"""Contract tests for the Selfhost Orchestrator manual dispatch surface."""

from pathlib import Path
import unittest

import yaml


ROOT = Path(__file__).resolve().parents[3]
WORKFLOW = ROOT / ".github/workflows/selfhost-orchestrator.yml"


class SelfhostDispatchContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        document = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))
        cls.dispatch = document.get("on", document.get(True))["workflow_dispatch"]
        cls.inputs = cls.dispatch["inputs"]

    def test_dispatch_has_the_planned_control_surface(self) -> None:
        expected = {
            "runner_type",
            "deploy_tag",
            "source_ref",
            "offline_mode",
            "source_host",
            "source_domain_base",
            "target_domain_base",
            "observability_endpoint",
            "xray_exporter_image",
            "operation",
            "target_domains",
            "open_platform_service",
            "cloud_provider",
            "cloud_account",
            "akamai_account",
            "include_external_agent_proxy",
            "instance_plan",
            "agent_proxy_plan",
            "dns_mode",
            "vault_env_path",
            "skip_stripe_catalog",
            "agent_controller_url",
            "vault_addr",
        }
        self.assertEqual(set(self.inputs), expected)
        self.assertLessEqual(len(self.inputs), 26)

    def test_safe_defaults_and_provider_registry_choices(self) -> None:
        self.assertEqual(self.inputs["runner_type"]["default"], "ubuntu-latest")
        self.assertEqual(self.inputs["operation"]["default"], "plan")
        self.assertEqual(self.inputs["offline_mode"]["default"], "off")
        self.assertEqual(self.inputs["cloud_provider"]["type"], "choice")
        self.assertEqual(
            self.inputs["cloud_provider"]["options"],
            ["aws-cloud", "gcp-cloud", "azure-cloud", "vultr-vps", "akamai-cloud"],
        )
        self.assertEqual(self.inputs["cloud_provider"]["default"], "akamai-cloud")
        self.assertEqual(self.inputs["akamai_account"]["default"], "")
        self.assertEqual(self.inputs["target_domain_base"]["default"], "onwalk.net")
        self.assertIn("all", self.inputs["target_domains"]["options"])
        self.assertEqual(self.inputs["open_platform_service"]["default"], "all")

    def test_operation_and_runtime_choices_are_explicit(self) -> None:
        self.assertEqual(
            self.inputs["operation"]["options"],
            ["plan", "infra", "deploy", "migrate", "deploy+migrate", "destroy"],
        )
        self.assertEqual(self.inputs["offline_mode"]["options"], ["off", "auto", "force"])
        self.assertEqual(self.inputs["dns_mode"]["options"], ["none", "uat-records", "prod-cutover"])
        self.assertEqual(self.inputs["vault_env_path"]["options"], ["sit", "uat", "prod"])
        self.assertEqual(self.inputs["agent_proxy_plan"]["default"], "1C2G")
        self.assertEqual(self.inputs["instance_plan"]["default"], "2C4G")


if __name__ == "__main__":
    unittest.main()
