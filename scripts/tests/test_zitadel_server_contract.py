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

    def test_doco_config_is_scoped_and_images_must_be_immutable(self):
        config = self.root / ".doco-cd.zitadel.yaml"
        config.write_text(yaml.safe_dump({"name": "shared-zitadel", "working_dir": "compose/zitadel",
                                         "compose_files": ["docker-compose.yml"], "env_files": [".env.shared"]}))
        env = self.root / "compose/zitadel/.env.shared"
        env.parent.mkdir(parents=True)
        env.write_text("\n".join(f"{key}=ghcr.io/{image}@sha256:{'a' * 64}" for key, image in (
            ("ZITADEL_IMAGE", "zitadel/zitadel"), ("ZITADEL_LOGIN_IMAGE", "zitadel/zitadel-login"),
            ("DOCO_CD_IMAGE", "kimdre/doco-cd"))))
        self.assertIn("@sha256:", MODULE.resolve_delivery(self.root)["doco_cd_image"])
        env.write_text(env.read_text().replace("@sha256:" + 'a' * 64, ":latest"))
        with self.assertRaises(ValueError):
            MODULE.resolve_delivery(self.root)

    def test_workflow_pins_doco_and_terraform_to_one_gitops_revision(self):
        workflow = yaml.safe_load((ROOT / ".github/workflows/zitadel-server.yml").read_text())
        jobs = workflow["jobs"]
        self.assertEqual(jobs["infrastructure"]["with"]["gitops_repo_ref"],
                         "${{ needs.declaration.outputs.gitops_sha }}")
        self.assertEqual(jobs["service"]["env"]["ZITADEL_GITOPS_SHA"],
                         "${{ needs.declaration.outputs.gitops_sha }}")
        script = (ROOT / ".github/scripts/service-deploy/zitadel.sh").read_text()
        self.assertIn('"zitadel_deployment_mode": "doco-cd"', script)

    def test_vault_selector_escapes_admin_key_with_jsonata_backticks(self):
        workflow_text = (ROOT / ".github/workflows/zitadel-server.yml").read_text()
        self.assertIn(
            "kv/data/shared/iam `zitadel-admin@zitadel.iam.svc.plus` | ZITADEL_ADMIN_PASSWORD",
            workflow_text,
        )


if __name__ == "__main__":
    unittest.main()
