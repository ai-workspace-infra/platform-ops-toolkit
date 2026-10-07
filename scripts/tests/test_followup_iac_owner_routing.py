import re
from pathlib import Path
import unittest

import yaml


ROOT = Path(__file__).resolve().parents[2]
SERVERLESS = ROOT / ".github/workflows/serverless-orchestrator.yml"
XCONNECT = ROOT / ".github/workflows/xconnect-zero-cloud.yaml"


def load(path: Path):
    return yaml.safe_load(path.read_text(encoding="utf-8"))


class FollowupIacOwnerRoutingTests(unittest.TestCase):
    def test_serverless_cloud_mutations_use_one_fixed_iac_owner(self):
        workflow = load(SERVERLESS)
        owner_calls = []
        for job in workflow["jobs"].values():
            if not isinstance(job, dict):
                continue
            for step in job.get("steps", []):
                uses = step.get("uses", "")
                if uses.startswith("ai-workspace-infra/iac_modules/.github/actions/"):
                    owner_calls.append(step)

        operations = {
            step.get("with", {}).get("operation")
            for step in owner_calls
            if step.get("with", {}).get("operation")
        }
        self.assertTrue({
            "registry-preflight", "smtp-sync", "cloud-run", "ssr",
            "frontend-router", "edge-gateway", "static-pages",
        }.issubset(operations))
        owner_refs = {step["uses"].rsplit("@", 1)[1] for step in owner_calls}
        self.assertEqual(len(owner_refs), 1)
        self.assertRegex(owner_refs.pop(), r"^[0-9a-f]{40}$")

        source = SERVERLESS.read_text(encoding="utf-8")
        for legacy_executor in (
            ".github/scripts/serverless/run_cloudflare_target.sh",
            ".github/scripts/serverless/sync_smtp_secrets.sh",
        ):
            self.assertNotIn(legacy_executor, source)

    def test_control_gates_stay_in_toolkit_and_consume_owner_facts(self):
        source = SERVERLESS.read_text(encoding="utf-8")
        for control_gate in (
            ".github/scripts/serverless/select-domain-owner.py",
            ".github/scripts/serverless/validate_portal_runtime_domains.sh",
            ".github/scripts/serverless/validate_dispatch_inputs.sh",
            ".github/scripts/serverless/validate_promotion_manifest.sh",
            ".github/scripts/serverless/verify_cloud_run_digest_facts.sh",
            ".github/scripts/serverless/record_image_digest.sh",
        ):
            self.assertIn(control_gate, source)
        self.assertIn("steps.cloud_run_facts.outputs.serving_digest", source)
        self.assertIn("steps.cloud_run_facts.outputs.traffic_revisions", source)

    def test_frozen_serverless_rollback_copies_are_preserved_but_uncalled(self):
        workflow_sources = "\n".join(
            path.read_text(encoding="utf-8") for path in (ROOT / ".github/workflows").glob("*.y*ml")
        )
        for relative in (
            ".github/scripts/serverless/run_cloudflare_target.sh",
            ".github/scripts/serverless/sync_smtp_secrets.sh",
            ".github/scripts/serverless/verify_frontend_boundary_assets.sh",
            ".github/scripts/serverless/verify_summary.sh",
        ):
            self.assertTrue((ROOT / relative).is_file(), relative)
            self.assertNotIn(relative, workflow_sources)

    def test_xconnect_checks_out_and_calls_the_same_immutable_iac_owner(self):
        source = XCONNECT.read_text(encoding="utf-8")
        default = re.search(
            r"(?ms)^\s+iac_ref:\n.*?^\s+default: '([0-9a-f]{40})'",
            source,
        )
        self.assertIsNotNone(default)
        owner_sha = default.group(1)
        self.assertIn(f"IAC_REF: ${{{{ inputs.iac_ref || '{owner_sha}' }}}}", source)
        self.assertGreaterEqual(
            source.count("uses: ./iac_modules/.github/actions/xconnect-lab-lifecycle"),
            5,
        )
        for operation in ("preflight", "prepare", "apply", "cleanup"):
            self.assertNotIn(f"run.sh {operation}", source)


if __name__ == "__main__":
    unittest.main()
