import base64
import importlib.util
import subprocess
import sys
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SCRIPT_DIR = ROOT / "scripts" / "node_deploy"
sys.path.insert(0, str(SCRIPT_DIR))


def load(name):
    spec = importlib.util.spec_from_file_location(name, SCRIPT_DIR / f"{name}.py")
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


legacy_source = load("legacy_source")
raft_operator = load("vault_raft_operator")
declaration = load("resolve_vault_server_declaration")
HOST_KEY = base64.b64encode(b"\x00\x00\x00\x0bssh-ed25519" + b"\x00\x00\x00\x20" + b"1" * 32).decode()


def service():
    return {
        "kind": "VaultServerDeployment",
        "metadata": {"name": "vault-server", "environment": "shared"},
        "spec": {
            "service_domain": "vault.svc.plus",
            "nodes": [{"id": "vault-prod-0"}, {"id": "vault-prod-1"}, {"id": "vault-prod-2"}],
            "access": {"bootstrap": "bootstrap-public", "steady_state": "xconnect-zero",
                       "xconnect_topology": "vpn-overlay/shared/xconnect-vault-shared.yaml"},
            "automation": {
                "github_environment": "prod",
                "vault_addr": "https://vault.svc.plus",
                "runtime_identity_path": "kv/data/shared/platform/oidc/open-platform-prod",
                "monitoring_secret_path": "kv/data/CICD/observability",
                "xconnect_secret_path": "kv/data/CICD/shared/xconnect",
                "node_role": "github-actions-platform-ops-toolkit-shared-vault-node-oidc-open-platform-prod",
                "monitoring_role": "github-actions-platform-ops-toolkit-shared-vault-monitoring",
                "xconnect_role": "github-actions-platform-ops-toolkit-shared-vault-xconnect",
                "raft_operator_role": "github-actions-platform-ops-toolkit-shared-vault-raft-operator",
            },
            "migration": {
                "raft_network": "overlay",
                "source": {
                    "id": "jp-xhttp-contabo",
                    "address": "jp-xhttp-contabo.svc.plus",
                    "ssh_user": "vault-migrate",
                    "ssh_host_ed25519": HOST_KEY,
                    "overlay_address": "10.79.0.10",
                },
                "ssh_ca": {
                    "role": "github-actions-platform-ops-toolkit-shared-vault-legacy-ssh",
                    "sign_path": "ssh-client-signer/sign/vault-legacy-ops",
                },
            },
            "backup": {
                "snapshot_role": "github-actions-platform-ops-toolkit-shared-vault-snapshot",
                "age_recipient": "age1" + "q" * 58,
                "destination": "s3://vault-backups/shared",
                "endpoint": "https://s3.example.net",
                "credentials_path": "kv/data/CICD/shared/vault-backup",
            },
        },
    }


def new_contract():
    return {
        "apiVersion": "ops.svc.plus/v1alpha1",
        "kind": "NodeDeployment",
        "metadata": {"name": "vault-shared"},
        "spec": {
            "environment": "shared",
            "stages": ["vault-shared-peers"],
            "stage_targets": {"vault-shared-peers": ["vault_shared_peers"]},
            "connection": {"mode": "bootstrap-public"},
            "nodes": [{
                "id": "vault-prod-0", "provider": "gcp", "address": "35.1.2.3",
                "private_address": "10.79.0.1", "overlay_address": "10.79.0.1",
                "ssh_user": "gha_1", "auth": {"adapter": "gcp-oslogin-ephemeral"},
                "groups": ["vault_shared_nodes", "vault_shared_peers"],
            }],
        },
    }


class LegacyContractTests(unittest.TestCase):
    def test_source_node_uses_a_certificate_and_its_overlay_address(self):
        contract = legacy_source.legacy_contract(service(), "vault-server")
        node = contract["spec"]["nodes"][0]
        self.assertEqual(node["auth"], {"adapter": "ssh-certificate", "principal": "vault-migrate"})
        self.assertEqual(node["private_address"], "10.79.0.10")
        self.assertIn("vault_legacy_source", node["groups"])
        self.assertIn("vault_shared_leader", node["groups"])
        self.assertIn("xconnect_one", node["groups"])
        self.assertEqual(contract["spec"]["stage_targets"], {
            "xconnect-one": ["xconnect_one"],
            "vault-legacy-convert": ["vault_legacy_source"],
            "vault-legacy-rollback": ["vault_legacy_source"],
            "vault-legacy-retire": ["vault_legacy_source"],
            "vault-single-raft": ["vault_single_node"],
        })

    def test_merge_combines_providers_into_one_contract(self):
        merged = legacy_source.merge([new_contract(), legacy_source.legacy_contract(service(), "vault-server")])
        self.assertEqual([node["id"] for node in merged["spec"]["nodes"]], ["vault-prod-0", "jp-xhttp-contabo"])
        self.assertEqual(
            set(merged["spec"]["stages"]),
            {"vault-shared-peers", "vault-single-raft", "vault-legacy-convert", "vault-legacy-rollback", "vault-legacy-retire",
             "xconnect-one"},
        )
        # M4: the old node is enrolled as One alongside the new peers.
        one_targets = merged["spec"]["stage_targets"]["xconnect-one"]
        self.assertIn("jp-xhttp-contabo", [
            node["id"] for node in merged["spec"]["nodes"] if set(node["groups"]) & set(one_targets)
        ])
        self.assertEqual(merged["spec"]["connection"], {"mode": "bootstrap-public"})

    def test_merge_rejects_duplicates_and_mixed_environments(self):
        legacy = legacy_source.legacy_contract(service(), "vault-server")
        with self.assertRaisesRegex(ValueError, "more than one contract"):
            legacy_source.merge([legacy, legacy])
        other = new_contract()
        other["spec"]["environment"] = "uat"
        with self.assertRaisesRegex(ValueError, "different environments"):
            legacy_source.merge([other, legacy])


class DeclarationTests(unittest.TestCase):
    def test_migration_and_backup_are_validated(self):
        values = declaration.resolve_migration(service(), "shared", "https://vault.svc.plus")
        self.assertEqual(values["migration"], "true")
        self.assertIn('"sign_path":"ssh-client-signer/sign/vault-legacy-ops"', values["legacy_config"])
        backup = declaration.resolve_backup(service(), "shared")
        self.assertIn('"destination":"s3://vault-backups/shared"', backup["backup_config"])

    def test_observation_window_is_validated_and_defaults_to_a_day(self):
        values = declaration.resolve_migration(service(), "shared", "https://vault.svc.plus")
        self.assertEqual(values["observation"], '{"hours":24}')
        document = service()
        document["spec"]["migration"]["observation"] = {
            "dns_switched_at": declaration.datetime.fromisoformat("2026-10-01T08:00:00+00:00"), "hours": 48,
        }
        values = declaration.resolve_migration(document, "shared", "https://vault.svc.plus")
        self.assertEqual(values["observation"], '{"dns_switched_at":"2026-10-01T08:00:00+00:00","hours":48}')
        document["spec"]["migration"]["observation"] = {"dns_switched_at": "2026-10-01T08:00:00"}
        with self.assertRaisesRegex(ValueError, "UTC offset"):
            declaration.resolve_migration(document, "shared", "https://vault.svc.plus")
        document["spec"]["migration"]["observation"] = {"dns_switched_at": "yesterday"}
        with self.assertRaisesRegex(ValueError, "ISO 8601"):
            declaration.resolve_migration(document, "shared", "https://vault.svc.plus")
        document["spec"]["migration"]["observation"] = {"hours": 0}
        with self.assertRaisesRegex(ValueError, "between 1 and 720"):
            declaration.resolve_migration(document, "shared", "https://vault.svc.plus")

    def test_absent_blocks_mean_a_fresh_install(self):
        document = service()
        del document["spec"]["migration"], document["spec"]["backup"]
        self.assertEqual(declaration.resolve_migration(document, "shared", "https://vault.svc.plus")["migration"], "false")
        self.assertEqual(declaration.resolve_backup(document, "shared")["backup_config"], "{}")

    def test_rejects_unsafe_migration_or_backup_settings(self):
        document = service()
        document["spec"]["migration"]["source"]["id"] = "vault-prod-1"
        with self.assertRaisesRegex(ValueError, "must not also be a declared new node"):
            declaration.resolve_migration(document, "shared", "https://vault.svc.plus")
        document = service()
        document["spec"]["migration"]["source"]["ssh_host_ed25519"] = ""
        with self.assertRaisesRegex(ValueError, "host key"):
            declaration.resolve_migration(document, "shared", "https://vault.svc.plus")
        document = service()
        document["spec"]["backup"]["credentials_path"] = "kv/data/CICD/uat/vault-backup"
        with self.assertRaisesRegex(ValueError, "this environment"):
            declaration.resolve_backup(document, "shared")
        document = service()
        document["spec"]["backup"]["age_recipient"] = "ssh-ed25519 AAAA"
        with self.assertRaisesRegex(ValueError, "age public key"):
            declaration.resolve_backup(document, "shared")


def config(leader, voters=("legacy", "n0", "n1", "n2")):
    return [{"node_id": node, "leader": node == leader, "voter": True, "address": f"{node}:8201"} for node in voters]


class RaftOperatorTests(unittest.TestCase):
    expected = ["n0", "n1", "n2"]

    def test_step_down_only_moves_leadership_off_the_source(self):
        self.assertTrue(raft_operator.plan_step_down(config("legacy"), "legacy", self.expected))
        self.assertFalse(raft_operator.plan_step_down(config("n1"), "legacy", self.expected))
        with self.assertRaisesRegex(ValueError, "not Raft voters"):
            raft_operator.plan_step_down(config("legacy", ("legacy", "n0")), "legacy", self.expected)

    def test_remove_requires_moved_leadership_and_no_strangers(self):
        with self.assertRaisesRegex(ValueError, "move leadership"):
            raft_operator.plan_remove(config("legacy"), "legacy", self.expected)
        self.assertTrue(raft_operator.plan_remove(config("n0"), "legacy", self.expected))
        self.assertFalse(raft_operator.plan_remove(config("n0", ("n0", "n1", "n2")), "legacy", self.expected))
        with self.assertRaisesRegex(ValueError, "undeclared Raft members"):
            raft_operator.plan_remove(config("n0", ("legacy", "n0", "n1", "n2", "old-x")), "legacy", self.expected)


class ControlPlaneBoundaryTests(unittest.TestCase):
    def test_host_side_migration_lives_in_playbooks_not_the_toolkit(self):
        self.assertFalse((SCRIPT_DIR / "legacy_convert.sh").exists())
        action = (SCRIPT_DIR / "run_stage_action.sh").read_text(encoding="utf-8")
        subprocess.run(["bash", "-n", str(SCRIPT_DIR / "run_stage_action.sh")], check=True)
        self.assertNotIn("ssh ", action)
        self.assertNotIn("legacy-convert", action)
        self.assertIn("vault_raft_operator.py", action)

    def test_run_stage_passes_extra_vars_to_ansible(self):
        source = (SCRIPT_DIR / "run_stage.sh").read_text(encoding="utf-8")
        subprocess.run(["bash", "-n", str(SCRIPT_DIR / "run_stage.sh")], check=True)
        self.assertIn("NODE_STAGE_EXTRA_VARS", source)
        self.assertIn('--extra-vars "${NODE_STAGE_EXTRA_VARS}"', source)
        self.assertIn("jq -e .", source)

    def test_run_stage_limits_one_node_stages_to_the_selected_target(self):
        source = (SCRIPT_DIR / "run_stage.sh").read_text(encoding="utf-8")
        self.assertIn("NODE_STAGE_ONLY", source)
        self.assertIn("is not a target of", source)

    def test_snapshot_is_restore_drilled_and_read_back(self):
        source = (SCRIPT_DIR / "vault_snapshot.sh").read_text(encoding="utf-8")
        # Drill before encryption, on the plaintext that is then encrypted.
        self.assertLess(source.index('drill "${snapshot}"'), source.index("age --encrypt"))
        self.assertIn("sys/storage/raft/snapshot-force", source)
        self.assertIn(".sealed == true", source)
        self.assertIn("env -u VAULT_TOKEN -u VAULT_ADDR", source)
        self.assertIn("readback.age", source)
        installer = (SCRIPT_DIR / "install_vault_drill.sh").read_text(encoding="utf-8")
        subprocess.run(["bash", "-n", str(SCRIPT_DIR / "install_vault_drill.sh")], check=True)
        self.assertIn("sha256sum --check", installer)

    def test_snapshot_script_only_uploads_ciphertext(self):
        source = (SCRIPT_DIR / "vault_snapshot.sh").read_text(encoding="utf-8")
        subprocess.run(["bash", "-n", str(SCRIPT_DIR / "vault_snapshot.sh")], check=True)
        self.assertIn("sha256sum --check", source)
        self.assertIn("age --encrypt", source)
        self.assertIn('rm -f -- "${snapshot}"', source)
        upload = source.index("s3 cp")
        self.assertLess(source.index('rm -f -- "${snapshot}"'), upload)


if __name__ == "__main__":
    unittest.main()
