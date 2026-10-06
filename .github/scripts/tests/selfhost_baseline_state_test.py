#!/usr/bin/env python3
"""Contract checks for first-deploy versus upgrade acceptance selection."""

import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[3]
SCRIPT = ROOT / ".github/scripts/environment-upgrade/read-selfhost-baseline-state.py"


class BaselineStateTest(unittest.TestCase):
    def run_reader(self, receipt, **overrides):
        with tempfile.TemporaryDirectory() as tmp:
            receipt_path = Path(tmp) / "baseline.json"
            output_path = Path(tmp) / "output"
            receipt_path.write_text(json.dumps(receipt), encoding="utf-8")
            env = os.environ.copy()
            env.update({
                "RECEIPT_PATH": str(receipt_path),
                "EXPECTED_PARENT_RUN_ID": "12345",
                "EXPECTED_BASELINE_RUN_ID": "23456",
                "EXPECTED_HOST": "web-saas-uat",
                "EXPECTED_ACCEPTANCE_RUN_ID": "12345",
                "GITHUB_OUTPUT": str(output_path),
            })
            env.update(overrides)
            result = subprocess.run(["python3", str(SCRIPT)], env=env, text=True, capture_output=True)
            output = output_path.read_text(encoding="utf-8") if output_path.exists() else ""
            return result, output

    def receipt(self, state):
        return {
            "schema": 1,
            "parent_workflow_run_id": "12345",
            "baseline_workflow_run_id": "23456",
            "target_host": "web-saas-uat",
            "acceptance_run_id": "12345",
            "captured_state": state,
            "row_counts": {},
        }

    def test_accepts_fresh_host_baseline_as_absent(self):
        result, output = self.run_reader(self.receipt("absent"))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(output, "captured_state=absent\n")

    def test_accepts_existing_database_baseline_as_present(self):
        result, output = self.run_reader(self.receipt("present"))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(output, "captured_state=present\n")

    def test_rejects_receipt_bound_to_another_parent(self):
        receipt = self.receipt("absent")
        receipt["parent_workflow_run_id"] = "99999"
        result, _ = self.run_reader(receipt)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("not bound", result.stderr)

    def test_rejects_unknown_database_state(self):
        result, _ = self.run_reader(self.receipt("unknown"))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("captured database evidence", result.stderr)


if __name__ == "__main__":
    unittest.main()
