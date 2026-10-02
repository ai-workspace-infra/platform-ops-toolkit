import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

VERIFIER = Path(__file__).resolve().parents[1] / "ci" / "workflow_script_refs_verify.py"

CHECKOUT_IAC = """
      - uses: actions/checkout@v7
        with:
          repository: ai-workspace-infra/iac_modules
          path: infra/iac_modules
"""


class WorkflowScriptRefsVerifyTest(unittest.TestCase):
    def setUp(self):
        self.root = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.root)
        self.repo = self.root / "toolkit"
        (self.repo / "scripts/ci").mkdir(parents=True)
        (self.repo / ".github/workflows").mkdir(parents=True)
        (self.repo / ".github/scripts").mkdir(parents=True)
        shutil.copy(VERIFIER, self.repo / "scripts/ci" / VERIFIER.name)
        self.iac = self.root / "iac_modules"
        (self.iac / "scripts/pipeline").mkdir(parents=True)
        script = self.iac / "scripts/pipeline/terraform-init.sh"
        script.write_text("#!/bin/bash\n")
        script.chmod(0o755)

    def verify(self, steps, with_iac=True):
        workflow = "on: push\njobs:\n  provision:\n    runs-on: ubuntu-latest\n    steps:\n"
        (self.repo / ".github/workflows/w.yml").write_text(workflow + steps.strip("\n") + "\n")
        command = [sys.executable, str(self.repo / "scripts/ci" / VERIFIER.name)]
        if with_iac:
            command += ["--iac-root", str(self.iac)]
        return subprocess.run(command, capture_output=True, text=True)

    def test_checked_out_sibling_script_passes(self):
        result = self.verify(CHECKOUT_IAC + """
      - run: ${{ github.workspace }}/infra/iac_modules/scripts/pipeline/terraform-init.sh
""")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("R1-R3", result.stdout)

    def test_missing_local_script_fails(self):
        result = self.verify("""
      - uses: actions/checkout@v7
      - run: ./.github/scripts/gone.sh
      - run: ${{ github.workspace }}/.github/scripts/gone-too.sh
      - run: bash "${GITHUB_WORKSPACE}/.github/scripts/gone-three.sh"
      - run: bash gitops/.github/scripts/not-ours.sh
""")
        self.assertEqual(result.returncode, 1)
        for name in ("gone.sh", "gone-too.sh", "gone-three.sh"):
            self.assertIn(f"R1 references .github/scripts/{name}", result.stderr)
        self.assertNotIn("not-ours.sh", result.stderr)

    def test_local_path_under_foreign_root_checkout_is_not_ours(self):
        result = self.verify("""
      - uses: actions/checkout@v7
        with:
          repository: ai-workspace-infra/playbooks
      - run: bash .github/scripts/gitops-update-tags.sh
""")
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_sibling_script_without_checkout_fails(self):
        result = self.verify("""
      - uses: actions/checkout@v7
      - run: ${{ github.workspace }}/infra/iac_modules/scripts/pipeline/terraform-init.sh
""")
        self.assertEqual(result.returncode, 1)
        self.assertIn("R3", result.stderr)

    def test_checkout_at_another_path_fails(self):
        result = self.verify(CHECKOUT_IAC + """
      - run: iac_modules/scripts/pipeline/terraform-init.sh
""")
        self.assertEqual(result.returncode, 1)
        self.assertIn("at path iac_modules", result.stderr)

    def test_conditional_checkout_needs_conditional_step(self):
        conditional = CHECKOUT_IAC.replace("      - uses:", "      - if: steps.route.outputs.run == 'true'\n        uses:")
        script = "${{ github.workspace }}/infra/iac_modules/scripts/pipeline/terraform-init.sh"
        self.assertEqual(self.verify(conditional + f"\n      - run: {script}\n").returncode, 1)
        guarded = conditional + f"\n      - if: steps.route.outputs.run == 'true'\n        run: {script}\n"
        self.assertEqual(self.verify(guarded).returncode, 0)

    def test_script_missing_in_sibling_fails(self):
        steps = CHECKOUT_IAC + """
      - run: ${{ github.workspace }}/infra/iac_modules/scripts/pipeline/renamed.sh
"""
        result = self.verify(steps)
        self.assertEqual(result.returncode, 1)
        self.assertIn("R4 ai-workspace-infra/iac_modules has no scripts/pipeline/renamed.sh", result.stderr)
        # Without the sibling checkout the existence check is skipped, not guessed.
        self.assertEqual(self.verify(steps, with_iac=False).returncode, 0)

    def test_bare_call_needs_exec_bit_but_interpreter_call_does_not(self):
        script = self.iac / "scripts/pipeline/terraform-init.sh"
        script.chmod(0o644)
        path = "${{ github.workspace }}/infra/iac_modules/scripts/pipeline/terraform-init.sh"
        bare = self.verify(CHECKOUT_IAC + f"\n      - run: {path}\n")
        self.assertEqual(bare.returncode, 1)
        self.assertIn("not executable", bare.stderr)
        self.assertEqual(self.verify(CHECKOUT_IAC + f"\n      - run: bash {path}\n").returncode, 0)

    def test_missing_reusable_workflow_and_action_fail(self):
        (self.repo / ".github/workflows/w.yml").write_text(
            "on: push\njobs:\n  call:\n    uses: ./.github/workflows/gone.yml\n"
            "  build:\n    runs-on: ubuntu-latest\n    steps:\n      - uses: ./.github/actions/gone\n")
        result = subprocess.run([sys.executable, str(self.repo / "scripts/ci" / VERIFIER.name)],
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 1)
        self.assertIn("reusable workflow ./.github/workflows/gone.yml", result.stderr)
        self.assertIn("./.github/actions/gone, which has no action.yml", result.stderr)


if __name__ == "__main__":
    unittest.main()
