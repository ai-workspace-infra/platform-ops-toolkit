import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
import yaml

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("zitadel", ROOT / ".github/scripts/service-deploy/resolve_zitadel.py")
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class ZitadelContractTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.path = self.root / "resources/iam.yaml"
        self.path.parent.mkdir()
        self.doc = {"metadata": {"name": "open-platform-shared-iam", "environment": "shared", "provider": "gcp"},
                    "spec": {"gcp_account_id": "open-platform-shared", "project_id": "open-platform-shared-510113",
                             "network_name": "iam", "enable_oslogin": True,
                             "resources": {"vault_nodes": [{"name": "iam-shared-0", "zone": "asia-east1-a",
                                                          "public_ip": True, "service_domains": ["iam.svc.plus"]}]}}}

    def resolve(self, action="none", stage="deploy", ref="refs/heads/main"):
        self.path.write_text(yaml.safe_dump(self.doc))
        return MODULE.resolve(self.root, "resources/iam.yaml", action, stage, ref)

    def test_real_project_is_preserved(self):
        self.assertEqual(self.resolve()["project"], "open-platform-shared-510113")

    def test_plan_cannot_deploy(self):
        with self.assertRaises(ValueError):
            self.resolve("plan", "deploy")

    def test_wrong_environment_empty_nodes_and_non_main_fail(self):
        with self.assertRaises(ValueError):
            self.resolve(ref="refs/heads/topic")
        self.doc["metadata"]["environment"] = "uat"
        with self.assertRaises(ValueError):
            self.resolve()
        self.doc["metadata"]["environment"] = "shared"
        self.doc["spec"]["resources"]["vault_nodes"] = []
        with self.assertRaises(ValueError):
            self.resolve()

    def test_optional_infra_skip_and_exact_vault_binding(self):
        workflow = yaml.safe_load((ROOT / ".github/workflows/zitadel-server.yml").read_text())
        service = workflow["jobs"]["service"]
        self.assertIn("always()", service["if"])
        self.assertIn("needs.infrastructure.result == 'skipped'", service["if"])
        self.assertEqual(service["environment"], "prod")
        role = json.loads((ROOT / "scripts/vault/roles/github-actions-platform-ops-toolkit-shared-zitadel.json").read_text())
        self.assertEqual(role["bound_claims"]["job_workflow_ref"],
                         "ai-workspace-infra/platform-ops-toolkit/.github/workflows/zitadel-server.yml@refs/heads/main")


if __name__ == "__main__":
    unittest.main()
