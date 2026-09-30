import os
import re
import subprocess
import tempfile
import unittest
from pathlib import Path

import yaml


ROOT = Path(__file__).resolve().parents[2]
WORKFLOW = ROOT / ".github/workflows/open-platform-orchestrator.yml"


class OpenPlatformOrchestratorContractTests(unittest.TestCase):
    def test_all_reconciles_shared_states_in_order_before_services(self):
        document = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))
        jobs = document["jobs"]

        self.assertEqual(jobs["vault-iac"]["needs"], "contract")
        self.assertEqual(jobs["observability-iac"]["needs"], ["contract", "vault-iac"])
        self.assertEqual(jobs["iam-iac"]["needs"], ["contract", "observability-iac"])
        self.assertEqual(
            jobs["services"]["needs"],
            ["contract", "vault-iac", "observability-iac", "iam-iac"],
        )

        self.assertIn("needs.vault-iac.result == 'success'", jobs["observability-iac"]["if"])
        self.assertIn("needs.observability-iac.result == 'success'", jobs["iam-iac"]["if"])

    def test_shared_vault_dispatch_uses_shared_target_manifest(self):
        document = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))
        jobs = document["jobs"]
        steps = jobs["services"]["steps"]
        dispatch_step = next(
            step
            for step in steps
            if step.get("name") == "Dispatch and wait for shared service workflows"
        )
        script = dispatch_step["run"]

        self.assertIn(
            'service_manifest:"resources/svc.plus/shared/vault/server.yaml"',
            script,
        )
        self.assertIn(
            'provider_manifest:"resources/svc.plus/shared/gcp/open-platform-shared-vault.yaml"',
            script,
        )
        self.assertIn(
            "dispatch_and_wait zitadel-server.yml \"ZITADEL deploy\"",
            script,
        )
        self.assertIn(
            'provider_manifest:"resources/svc.plus/shared/gcp/open-platform-shared-iam.yaml"',
            script,
        )
        self.assertIn('--arg vault_addr "${VAULT_ADDR}"', script)
        self.assertLess(
            script.index('dispatch_and_wait zitadel-server.yml "ZITADEL deploy"'),
            script.index('dispatch_and_wait observability-server.yml'),
        )
        self.assertNotIn(
            'provider_manifest:"resources/xworktech.com/shared/gcp/vault-shared.yaml"',
            script,
        )


    def _dispatch_script(self):
        document = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))
        steps = document["jobs"]["services"]["steps"]
        return next(
            step for step in steps if step.get("name") == "Dispatch and wait for shared service workflows"
        )["run"]

    def test_every_dispatch_payload_matches_its_target_workflow_inputs(self):
        # A dispatched input the child does not declare, an invalid choice, or
        # a manifest path the child rejects only fails after the preceding
        # service stages have already run. Assert the contract here instead.
        script = self._dispatch_script()
        targets = {
            "vault_payload": "vault-server.yml",
            "zitadel_payload": "zitadel-server.yml",
            "observability_payload": "observability-server.yml",
        }
        for variable, workflow in targets.items():
            with self.subTest(workflow=workflow):
                match = re.search(variable + r'="\$\(jq -n(.*?)\)"\n', script, re.S)
                self.assertIsNotNone(match, f"{variable} is not built with jq")
                body = re.search(r"'\{ref:\$ref,inputs:\{(.*)\}\}'", match.group(1), re.S).group(1)
                sent = re.findall(r"(?:^|,)([a-z_]+):", body)
                literals = dict(re.findall(r'([a-z_]+):"([^"]*)"', body))
                target = yaml.safe_load((ROOT / ".github/workflows" / workflow).read_text(encoding="utf-8"))
                declared = (target.get("on") or target[True])["workflow_dispatch"]["inputs"]

                self.assertTrue(sent)
                for key in sent:
                    self.assertIn(key, declared, f"{workflow} does not declare input {key}")
                for key, value in literals.items():
                    spec = declared[key]
                    if spec.get("type") == "choice":
                        self.assertIn(value, spec["options"], f"{workflow} rejects {key}={value}")
                    if key.endswith("manifest"):
                        self.assertEqual(value, spec["default"], f"{workflow} {key} must be its reviewed declaration")

    def test_observability_dispatch_uses_shared_observability_manifest(self):
        script = self._dispatch_script()
        self.assertIn(
            'gcp_resource_manifest:"resources/svc.plus/shared/gcp/open-platform-shared-observability.yaml"',
            script,
        )
        self.assertFalse("resources.svc.plus" in script, "Observability manifest path contains resources.svc.plus")

    def _run_dispatch(self, run_states, run_list_failures=0):
        """Run the real dispatch script for one child against a fake gh CLI."""
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            (tmp / "states").write_text("\n".join(run_states) + "\n")
            (tmp / "run_list_failures").write_text(str(run_list_failures))
            fake = tmp / "gh"
            fake.write_text("""#!/usr/bin/env bash
set -u
d="$(dirname "$0")"
echo "$*" >> "$d/calls"
case "$1 $2" in
  "workflow list") echo 4242 ;;
  "run list")
    n="$(cat "$d/run_list_failures")"
    if [ "$n" -gt 0 ]; then echo $((n - 1)) > "$d/run_list_failures"; echo 'HTTP 502' >&2; exit 1; fi
    echo 9001 ;;
  *)
    if [ "$2" = "--method" ]; then cat >/dev/null; exit 0; fi
    line="$(head -n 1 "$d/states")"; sed -i 1d "$d/states"
    [ -n "$line" ] || line="$(tail -n 1 "$d/last")"
    echo "$line" > "$d/last"
    if [ "$line" = ERROR ]; then echo 'HTTP 502: Server Error' >&2; exit 1; fi
    printf '%b\n' "$line" ;;
esac
""")
            fake.chmod(0o755)
            env = dict(os.environ, PATH=f"{tmp}:{os.environ['PATH']}", GITHUB_REPOSITORY="o/r",
                       CHILD_POLL_INTERVAL_SECONDS="0", CHILD_MAX_READ_FAILURES="3",
                       TARGET_SERVICES="observability", OPERATION="upgrade", DEPLOY_TAG="daily-build-2026.09.28-r5",
                       GITOPS_REF="main", OBS_MIGRATION="none", OBS_SOURCE_IP="", OBS_TARGET_IP="",
                       OBS_WRITERS_PAUSED="false", OBS_HISTORY_VERIFIED="false", OBS_HISTORY_OMITTED="false")
            result = subprocess.run(["bash", "-c", self._dispatch_script()], env=env,
                                    capture_output=True, text=True, timeout=60)
            calls = (tmp / "calls").read_text().splitlines()
            posts = [call for call in calls if "--method POST" in call]
            return result, posts

    def test_transient_api_errors_do_not_fail_a_running_child(self):
        result, posts = self._run_dispatch(["ERROR", "in_progress\\t", "ERROR", "ERROR", "completed\\tsuccess"])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(posts), 1, "the dispatch must never be retried")
        self.assertIn("succeeded", result.stdout)

    def test_run_lookup_survives_a_transient_error_without_redispatch(self):
        result, posts = self._run_dispatch(["completed\\tsuccess"], run_list_failures=1)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(posts), 1)

    def test_child_failure_still_fails_the_parent(self):
        result, posts = self._run_dispatch(["in_progress\\t", "completed\\tfailure"])
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("concluded failure", result.stderr)
        self.assertEqual(len(posts), 1)

    def test_persistently_unreadable_child_fails_the_parent(self):
        result, posts = self._run_dispatch(["ERROR"])
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("could not read", result.stderr)
        self.assertEqual(len(posts), 1)

if __name__ == "__main__":
    unittest.main()
