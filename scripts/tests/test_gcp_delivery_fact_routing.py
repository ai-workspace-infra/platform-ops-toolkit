import os
import subprocess
import unittest
from pathlib import Path

import yaml


ROOT = Path(__file__).resolve().parents[2]
OWNER_SHA = "8373e926a6f7ba37a59a7b7ee864c7e87b102f58"
SERVERLESS = ROOT / ".github/workflows/serverless-orchestrator.yml"
DIAGNOSTICS = ROOT / ".github/workflows/prod-agent-proxy-diagnostics.yml"
GATE = ROOT / ".github/scripts/serverless/verify_cloud_run_digest_facts.sh"


def load(path: Path):
    return yaml.safe_load(path.read_text(encoding="utf-8"))


class GcpDeliveryFactRoutingTests(unittest.TestCase):
    def test_serverless_routes_gcp_readers_and_cloud_queries_to_owner(self):
        workflow = load(SERVERLESS)
        source = SERVERLESS.read_text(encoding="utf-8")
        self.assertNotIn("run: ruby ./.github/scripts/gitops/read_gcp_gitops_target.rb", source)
        self.assertNotIn("run: ruby ./.github/scripts/gitops/validate_gcp_gitops_contract.rb", source)
        self.assertNotIn("run: ./.github/scripts/serverless/verify_cloud_run_image_digest.sh", source)
        cloud_steps = workflow["jobs"]["cloud_run"]["steps"]
        owner_checkouts = [
            step for step in cloud_steps
            if step.get("with", {}).get("repository") == "ai-workspace-infra/iac_modules"
            and step.get("with", {}).get("ref") == OWNER_SHA
        ]
        self.assertEqual(len(owner_checkouts), 1)
        self.assertIn(".github/actions/cloud-run-serving-facts", owner_checkouts[0]["with"]["sparse-checkout"])
        self.assertEqual(sum(step.get("uses") == "./iac_modules/.github/actions/gitops-gcp-target" for step in cloud_steps), 2)
        self.assertEqual(sum(step.get("uses") == "./iac_modules/.github/actions/cloud-run-serving-facts" for step in cloud_steps), 1)
        query = next(step for step in cloud_steps if step.get("id") == "cloud_run_facts")
        self.assertIn("steps.promoted.outputs.digest", query["with"]["artifact-digest"])
        gate = next(step for step in cloud_steps if step.get("run") == "./.github/scripts/serverless/verify_cloud_run_digest_facts.sh")
        self.assertIn("steps.cloud_run_facts.outputs.serving_digest", gate["env"]["SERVING_DIGEST"])

    def test_destroy_reader_and_aws_diagnostics_use_fixed_owner(self):
        serverless = load(SERVERLESS)
        destroy = serverless["jobs"]["destroy"]["steps"]
        checkout = next(step for step in destroy if step.get("with", {}).get("repository") == "ai-workspace-infra/iac_modules")
        self.assertEqual(checkout["with"]["ref"], OWNER_SHA)
        self.assertEqual(sum(step.get("uses") == "./iac_modules/.github/actions/gitops-gcp-target" for step in destroy), 2)

        diagnostics = load(DIAGNOSTICS)["jobs"]["inspect"]["steps"]
        checkout = next(step for step in diagnostics if step.get("with", {}).get("repository") == "ai-workspace-infra/iac_modules")
        self.assertEqual(checkout["with"]["ref"], OWNER_SHA)
        reader = next(step for step in diagnostics if step.get("id") == "aws_oidc")
        self.assertEqual(reader["uses"], "./iac_modules/.github/actions/gitops-aws-oidc")
        self.assertEqual(reader["with"]["account"], "950604983695")

    def test_final_digest_gate_accepts_only_artifact_or_exact_child_and_one_revision(self):
        digest = "sha256:" + "a" * 64
        child = "sha256:" + "b" * 64
        base = {
            **os.environ,
            "CLOUD_RUN_SERVICE_NAME": "uat-accounts",
            "EXPECTED_DIGEST": digest,
            "LATEST_READY_REVISION": "accounts-00042",
            "TRAFFIC_REVISIONS": '["accounts-00042"]',
            "SERVING_DIGEST": child,
            "LINUX_AMD64_CHILD_DIGEST": child,
        }
        accepted = subprocess.run(["bash", str(GATE)], env=base, text=True, capture_output=True)
        self.assertEqual(accepted.returncode, 0, accepted.stderr)
        stray = {**base, "TRAFFIC_REVISIONS": '["accounts-00041","accounts-00042"]'}
        result = subprocess.run(["bash", str(GATE)], env=stray, text=True, capture_output=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("traffic still reaches", result.stderr)
        mismatch = {**base, "SERVING_DIGEST": "sha256:" + "c" * 64}
        result = subprocess.run(["bash", str(GATE)], env=mismatch, text=True, capture_output=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("not", result.stderr)

    def test_frozen_legacy_implementations_remain_for_uat_rollback_only(self):
        for path in (
            ROOT / ".github/scripts/gitops/read_gcp_gitops_target.rb",
            ROOT / ".github/scripts/gitops/validate_gcp_gitops_contract.rb",
            ROOT / ".github/scripts/gitops/resolve_gitops_aws_oidc_config.sh",
            ROOT / ".github/scripts/serverless/verify_cloud_run_image_digest.sh",
        ):
            self.assertTrue(path.is_file(), path)


if __name__ == "__main__":
    unittest.main()
