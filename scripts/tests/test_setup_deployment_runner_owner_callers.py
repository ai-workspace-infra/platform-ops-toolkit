import pathlib
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]
OWNER_SHA = "18fa333e5d76143f2a3a3ce94b1766a04003ebd8"
SETUP = f"ai-workspace-infra/playbooks/.github/actions/setup-deployment-runner@{OWNER_SHA}"


class SetupDeploymentRunnerOwnerCallerTests(unittest.TestCase):
    def test_all_thirteen_callers_pin_the_owner_sha(self):
        paths = [
            ROOT / ".github/workflows/deploy-action-runner-iac.yaml",
            ROOT / ".github/workflows/observability-server.yml",
            ROOT / ".github/workflows/selfhost-orchestrator.yml",
        ]
        calls = sum(path.read_text(encoding="utf-8").count(SETUP) for path in paths)
        self.assertEqual(calls, 13)
        for path in paths:
            self.assertNotIn("uses: ./.github/actions/setup-deployment-runner", path.read_text(encoding="utf-8"))

    def test_legacy_copy_remains_until_uat(self):
        self.assertTrue((ROOT / ".github/actions/setup-deployment-runner/action.yml").is_file())
        source = (ROOT / ".github/actions/setup-deployment-runner/scripts/setup.sh").read_text()
        self.assertIn("systemctl disable unattended-upgrades.service", source)


if __name__ == "__main__":
    unittest.main()
