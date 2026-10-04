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
        checkout = steps[names.index("Checkout reviewed Vultr snapshot executor")]
        backup = steps[names.index("Create backup snapshot")]

        self.assertLess(names.index("Preflight current instance and resize direction"), names.index("Checkout reviewed Vultr snapshot executor"))
        self.assertLess(names.index("Checkout reviewed Vultr snapshot executor"), names.index("Create backup snapshot"))
        self.assertEqual(checkout["if"], backup["if"])
        self.assertEqual(checkout["with"]["repository"], "ai-workspace-infra/iac_modules")
        self.assertEqual(checkout["with"]["ref"], "80076438ffa268d10ed3bbe32235a3d7c52f457e")
        self.assertEqual(checkout["with"]["path"], "iac_modules")
        self.assertEqual(backup["run"], "${{ github.workspace }}/iac_modules/scripts/pipeline/vultr-instance-snapshot.sh")
        self.assertNotIn("resize-instance_vultr-vps_create-backup.sh", (ROOT / ".github/workflows/resize-instance.yaml").read_text())


if __name__ == "__main__":
    unittest.main()
