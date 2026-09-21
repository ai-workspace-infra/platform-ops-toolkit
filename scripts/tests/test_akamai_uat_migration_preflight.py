"""Offline unit tests for the read-only Akamai UAT migration inventory."""

from __future__ import annotations

import hashlib
import importlib.util
import io
import json
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / ".github/scripts/platform-ops/provision/akamai-uat-migration-preflight.py"
SPEC = importlib.util.spec_from_file_location("akamai_preflight", SCRIPT)
PREFLIGHT = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(PREFLIGHT)


def identity(resource_type: str, resource_id: str, label: str) -> str:
    payload = json.dumps([resource_type, resource_id, label, ""], separators=(",", ":"))
    return hashlib.sha256(payload.encode()).hexdigest()


def expected_rows() -> list[dict[str, str]]:
    return [
        {
            "namespace": namespace,
            "manifest": f"resources/svc.plus/uat/akamai/{namespace}.yaml",
            "label": f"{namespace}-host",
            "firewall_label": f"{namespace}-host-firewall",
            "region": "",
            "type": "g6-standard-1",
        }
        for namespace in PREFLIGHT.NAMESPACES
    ]


def state_record(address: str, namespace: str, resource_type: str, resource_id: str, label: str) -> dict[str, str]:
    return {
        "address": address,
        "namespace": namespace,
        "state_key": f"terraform/uat/svc.plus/akamai-cloud/manbuzhe2026/{namespace}/terraform.tfstate",
        "resource_type": resource_type,
        "id": resource_id,
        "label": label,
        "identity_sha256": identity(resource_type, resource_id, label),
        "identity_complete": bool(resource_id),
    }


class PreflightContractTests(unittest.TestCase):
    def test_exact_legacy_key_is_historically_derived(self) -> None:
        candidate = PREFLIGHT.LEGACY_STATE_CANDIDATES[0]
        self.assertEqual(
            candidate["state_key"],
            "terraform/uat/platform-ops-toolkit/akamai-cloud/manbuzhe2026/selfhost/terraform.tfstate",
        )
        self.assertEqual(candidate["source_commit"], "77d3a51f5b39f420ebee4fe07a22b442ddd3b206")

    def test_terraform_and_aws_commands_are_read_only_allowlists(self) -> None:
        self.assertEqual(
            PREFLIGHT.READ_ONLY_TERRAFORM_COMMANDS,
            {("init",), ("show",)},
        )
        self.assertEqual(
            PREFLIGHT.READ_ONLY_AWS_COMMANDS,
            {("s3api", "list-object-versions"), ("s3api", "head-object")},
        )
        with self.assertRaises(PREFLIGHT.PreflightError):
            PREFLIGHT._terraform_call(Path("/tmp"), ["apply"], {})
        with self.assertRaises(PREFLIGHT.PreflightError):
            PREFLIGHT._terraform_call(Path("/tmp"), ["state", "rm", "linode_instance.x"], {})
        with self.assertRaises(PREFLIGHT.PreflightError):
            PREFLIGHT._terraform_call(Path("/tmp"), ["state", "push", "state.json"], {})
        with patch.object(PREFLIGHT.subprocess, "run") as run:
            run.return_value = SimpleNamespace(returncode=0)
            PREFLIGHT._terraform_call(Path("/tmp"), ["show", "-json"], {})
            command = run.call_args.args[0]
            self.assertEqual(command[-2:], ["show", "-json"])
        with self.assertRaises(PREFLIGHT.PreflightError):
            PREFLIGHT._terraform_call(Path("/tmp"), ["state", "show", "-json"], {})
        with self.assertRaises(PREFLIGHT.PreflightError):
            PREFLIGHT._aws_readonly(["s3api", "delete-object"], {})

    def test_state_reader_generates_valid_multiline_s3_backend_block(self) -> None:
        backend_env = {
            "TF_STATE_ENDPOINT": "https://s3.us-east-1.amazonaws.com",
            "TF_STATE_BUCKET": "example-state",
            "TF_STATE_ACCESS_KEY": "test-access-key",
            "TF_STATE_SECRET_KEY": "test-secret-key",
            "TF_STATE_REGION": "us-east-1",
        }

        def terraform_call(root, args, _env):
            if args[0] == "init":
                self.assertEqual(
                    (root / "main.tf").read_text(encoding="utf-8"),
                    'terraform {\n  backend "s3" {}\n}\n',
                )
                return SimpleNamespace(returncode=0, stdout="", stderr="")
            return SimpleNamespace(
                returncode=1,
                stdout="",
                stderr="No state file was found",
            )

        with patch.object(PREFLIGHT, "_terraform_call", side_effect=terraform_call):
            state = PREFLIGHT.inspect_terraform_state("terraform/test.tfstate", backend_env)
        self.assertFalse(state["present"])

    def test_terraform_show_json_recursively_projects_only_managed_allowlisted_fields(self) -> None:
        output = json.dumps(
            {
                "values": {
                    "root_module": {
                        "resources": [
                            {
                                "address": "linode_instance.host",
                                "mode": "managed",
                                "type": "linode_instance",
                                "values": {
                                    "id": 1234,
                                    "label": "agent-proxy-jp-host",
                                    "root_pass": "do-not-emit-this",
                                    "user_data": "private-payload",
                                },
                            },
                            {
                                "address": "data.linode_instance.lookup",
                                "mode": "data",
                                "type": "linode_instance",
                                "values": {"id": 1234, "label": "ignored"},
                            },
                        ],
                        "child_modules": [
                            {
                                "address": "module.firewall",
                                "resources": [
                                    {
                                        "address": "module.firewall.linode_firewall.this",
                                        "mode": "managed",
                                        "type": "linode_firewall",
                                        "values": {"id": 77, "label": "agent-proxy-jp-host-firewall"},
                                    }
                                ],
                                "child_modules": [],
                            }
                        ],
                    }
                },
            }
        )
        resources, protected, present = PREFLIGHT.parse_terraform_show_json(output)
        self.assertFalse(protected)
        self.assertTrue(present)
        self.assertEqual([item["address"] for item in resources], [
            "linode_instance.host",
            "module.firewall.linode_firewall.this",
        ])
        self.assertEqual(resources[0]["id"], "1234")
        self.assertNotIn("root_pass", json.dumps(resources))
        self.assertNotIn("do-not-emit-this", json.dumps(resources))
        self.assertNotIn("private-payload", json.dumps(resources))

    def test_protected_source_is_detected_without_emitting_state(self) -> None:
        resources, protected, _present = PREFLIGHT.parse_terraform_show_json(
            json.dumps({"values": {"root_module": {"resources": [
                {"address": "module.example.random_id.x", "mode": "managed", "type": "random_id",
                 "values": {"id": "x", "note": "observability.svc.plus"}}
            ], "child_modules": []}}})
        )
        self.assertTrue(protected)
        self.assertNotIn("observability.svc.plus", json.dumps(resources))

    def test_generator_import_supports_sibling_modules_and_manifest_path_string(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            scripts = root / "terraform-hcl-standard/akamai-cloud/scripts"
            scripts.mkdir(parents=True)
            (scripts / "state_contract.py").write_text("VALUE = 'loaded'\n", encoding="utf-8")
            (scripts / "generate.py").write_text(
                "from state_contract import VALUE\n" "IMPORT_VALUE = VALUE\n", encoding="utf-8"
            )
            module = PREFLIGHT._load_generator(root)
            self.assertEqual(module.IMPORT_VALUE, "loaded")

        class Generator:
            @staticmethod
            def load_sources(source):
                if not isinstance(source, str):
                    raise TypeError("expected a path string")
                namespace = Path(source).stem
                return {"state_namespace": namespace}, [], [{"label": f"{namespace}-host", "region": "jp-tyo-3", "type": "g6-standard-1"}]

            @staticmethod
            def firewall_label(label):
                return f"{label}-firewall"

        with tempfile.TemporaryDirectory() as temporary:
            gitops = Path(temporary)
            manifest_dir = gitops / "resources/svc.plus/uat/akamai"
            manifest_dir.mkdir(parents=True)
            for namespace in PREFLIGHT.NAMESPACES:
                (manifest_dir / f"{namespace}.yaml").write_text("{}\n", encoding="utf-8")
            with patch.object(PREFLIGHT, "_load_generator", return_value=Generator()):
                expectations = PREFLIGHT.load_manifest_expectations(gitops, Path("unused"))
        self.assertEqual(len(expectations), 6)
        self.assertEqual(expectations[0]["label"], "web-saas-host")

    def test_protected_endpoint_is_allowed_but_protected_managed_identity_is_rejected(self) -> None:
        class Generator:
            protected_identity = False

            @classmethod
            def load_sources(cls, source):
                namespace = Path(source).stem
                host = {
                    "name": PREFLIGHT.PROTECTED_SOURCE if cls.protected_identity and namespace == "open-platform" else namespace,
                    "label": f"{namespace}-host",
                    "type": "g6-standard-1",
                    "host_vars": {"service_domains": [PREFLIGHT.PROTECTED_SOURCE]},
                }
                return {"state_namespace": namespace}, [], [host]

            @staticmethod
            def firewall_label(label):
                return f"{label}-firewall"

        with tempfile.TemporaryDirectory() as temporary:
            gitops = Path(temporary)
            manifest_dir = gitops / "resources/svc.plus/uat/akamai"
            manifest_dir.mkdir(parents=True)
            for namespace in PREFLIGHT.NAMESPACES:
                (manifest_dir / f"{namespace}.yaml").write_text(
                    f"service_domains: [{PREFLIGHT.PROTECTED_SOURCE}]\n", encoding="utf-8"
                )
            with patch.object(PREFLIGHT, "_load_generator", return_value=Generator()):
                self.assertEqual(len(PREFLIGHT.load_manifest_expectations(gitops, Path("unused"))), 6)
                Generator.protected_identity = True
                with self.assertRaisesRegex(PREFLIGHT.PreflightError, "protected_source_as_managed_host:open-platform"):
                    PREFLIGHT.load_manifest_expectations(gitops, Path("unused"))

    def test_linode_client_uses_get_only_and_allowlisted_paths(self) -> None:
        captured = []

        class Response(io.BytesIO):
            def __enter__(self):
                return self

            def __exit__(self, *_args):
                self.close()

        def fake_open(request, timeout):
            captured.append((request.method, request.full_url, timeout))
            return Response(b'{"data":[],"page":1,"pages":1,"results":0}')

        with patch.object(PREFLIGHT, "urlopen", side_effect=fake_open):
            self.assertEqual(PREFLIGHT.linode_get_pages("linode/instances", "fake-token"), [])
        self.assertEqual(captured[0][0], "GET")
        self.assertIn("/v4/linode/instances?", captured[0][1])
        with self.assertRaises(PREFLIGHT.PreflightError):
            PREFLIGHT.linode_get_pages("linode/instances/123/delete", "fake-token")

    def test_absent_and_unmanaged_statuses(self) -> None:
        expected = expected_rows()
        report = PREFLIGHT.build_report(
            expected,
            [{"id": 9, "label": expected[0]["label"], "region": "jp-tyo-3"}],
            [],
            [{"state_key": PREFLIGHT.LEGACY_STATE_CANDIDATES[0]["state_key"], "present": False, "resources": [], "protected_text": False}],
        )
        statuses = {item["namespace"]: item["status"] for item in report["namespaces"]}
        self.assertEqual(statuses["web-saas"], "existing-unmanaged")
        self.assertEqual(statuses["open-platform"], "absent")
        self.assertFalse(next(item for item in report["namespaces"] if item["namespace"] == "open-platform")["cleanup_eligible"])

    def test_old_resource_maps_one_to_one_to_namespace_state(self) -> None:
        expected = expected_rows()
        legacy_key = PREFLIGHT.LEGACY_STATE_CANDIDATES[0]["state_key"]
        resource = state_record("linode_instance.legacy[\"x\"]", "selfhost", "linode_instance", "45", expected[0]["label"])
        old = {"state_key": legacy_key, "present": True, "resources": [resource], "protected_text": False}
        targets = [
            {
                "state_key": f"terraform/uat/svc.plus/akamai-cloud/manbuzhe2026/{row['namespace']}/terraform.tfstate",
                "namespace": row["namespace"],
                "present": row["namespace"] == "web-saas",
                "resources": [state_record("linode_instance.host", row["namespace"], "linode_instance", "45", row["label"])] if row["namespace"] == "web-saas" else [],
                "protected_text": False,
            }
            for row in expected
        ]
        report = PREFLIGHT.build_report(expected, [], [], [old, *targets])
        mapping = report["retirement_plan"]["resource_mappings"][0]
        self.assertEqual(mapping["mapping_status"], "one-to-one")
        self.assertEqual(mapping["target_namespace"], "web-saas")
        self.assertEqual(mapping["target_address"], "linode_instance.host")
        self.assertEqual(report["retirement_plan"]["mapping_counts"]["unmapped"], 0)
        self.assertFalse(report["retirement_plan"]["state_rm_or_retire_allowed"])

    def test_duplicate_target_identity_fails_preflight(self) -> None:
        expected = expected_rows()
        legacy_key = PREFLIGHT.LEGACY_STATE_CANDIDATES[0]["state_key"]
        resource = state_record("linode_instance.legacy", "selfhost", "linode_instance", "55", expected[0]["label"])
        old = {"state_key": legacy_key, "present": True, "resources": [resource], "protected_text": False}
        targets = [
            {
                "state_key": f"terraform/uat/svc.plus/akamai-cloud/manbuzhe2026/{namespace}/terraform.tfstate",
                "namespace": namespace,
                "present": True,
                "resources": [state_record(f"linode_instance.{namespace}", namespace, "linode_instance", "55", expected[0]["label"])] if namespace in {"web-saas", "ai-workspace"} else [],
                "protected_text": False,
            }
            for namespace in PREFLIGHT.NAMESPACES
        ]
        report = PREFLIGHT.build_report(expected, [], [], [old, *targets])
        self.assertEqual(report["retirement_plan"]["mapping_counts"]["duplicate"], 1)
        self.assertIn("legacy_resource_maps_to_multiple_target_states", report["failures"])

    def test_protected_source_and_open_platform_cleanup_are_fail_closed(self) -> None:
        expected = expected_rows()
        legacy_key = PREFLIGHT.LEGACY_STATE_CANDIDATES[0]["state_key"]
        old = {"state_key": legacy_key, "present": True, "resources": [], "protected_text": True}
        report = PREFLIGHT.build_report(expected, [], [], [old])
        self.assertIn("protected_source_present_in_akamai_state", report["failures"])
        self.assertNotIn("open-platform", report["future_cleanup_namespaces"])


if __name__ == "__main__":
    unittest.main()
