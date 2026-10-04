"""The resize workflow invokes the reviewed IaC snapshot executor, not a copy."""

import unittest
from pathlib import Path

import yaml


ROOT = Path(__file__).resolve().parents[2]


class ResizeSnapshotOwnerContractTests(unittest.TestCase):
    def test_reviewed_owner_checkout_precedes_conditional_backup(self):
        workflow = yaml.safe_load((ROOT / ".github/workflows/resize-instance.yaml").read_text())
        steps = workflow["jobs"]["resize"]["steps"]
        names = [step.get("name") for step in steps]
        checkout = steps[names.index("Checkout reviewed resize provider executors")]
        backup = steps[names.index("Create backup snapshot")]

        self.assertLess(names.index("Preflight current instance and resize direction"), names.index("Checkout reviewed resize provider executors"))
        self.assertLess(names.index("Checkout reviewed resize provider executors"), names.index("Create backup snapshot"))
        self.assertEqual(checkout["if"], backup["if"])
        self.assertEqual(checkout["with"]["repository"], "ai-workspace-infra/iac_modules")
        self.assertEqual(checkout["with"]["ref"], "65cd4b6f28df667bd7df3614557b4ff41dfc1dd5")
        self.assertEqual(checkout["with"]["path"], "iac_modules")
        self.assertEqual(backup["run"], "${{ github.workspace }}/iac_modules/scripts/pipeline/vultr-instance-snapshot.sh")
        self.assertNotIn("resize-instance_vultr-vps_create-backup.sh", (ROOT / ".github/workflows/resize-instance.yaml").read_text())

    def test_cutover_and_destroy_use_same_reviewed_owner_after_guards(self):
        workflow = yaml.safe_load((ROOT / ".github/workflows/resize-instance.yaml").read_text())
        steps = workflow["jobs"]["resize"]["steps"]
        names = [step.get("name") for step in steps]
        dns = steps[names.index("Switch DNS after health check")]
        destroy = steps[names.index("Destroy source instance only after explicit confirmation")]

        self.assertLess(names.index("Health check replacement"), names.index("Switch DNS after health check"))
        self.assertLess(names.index("Switch DNS after health check"), names.index("Observation window"))
        self.assertLess(names.index("Observation window"), names.index("Destroy source instance only after explicit confirmation"))
        self.assertIn("inputs.switch_dns", dns["if"])
        self.assertIn("inputs.destroy_old_instance", destroy["if"])
        self.assertEqual(destroy["env"]["CONFIRM_DESTROY"], "${{ inputs.destroy_old_instance }}")
        self.assertEqual(dns["run"], "${{ github.workspace }}/iac_modules/scripts/pipeline/cloudflare-dns-cutover.sh")
        self.assertEqual(destroy["run"], "${{ github.workspace }}/iac_modules/scripts/pipeline/vultr-destroy-source-instance.sh")
        self.assertNotIn("resize-instance_switch-dns.sh", (ROOT / ".github/workflows/resize-instance.yaml").read_text())
        self.assertNotIn("resize-instance_destroy-old.sh", (ROOT / ".github/workflows/resize-instance.yaml").read_text())


if __name__ == "__main__":
    unittest.main()
