"""Regression coverage for optional serverless runtime secret groups."""
import unittest

from deploy_orchestrator import optional_runtime_secrets


class OptionalRuntimeSecretTests(unittest.TestCase):
    KEYS = {
        "PRIVATE": "ZERO_SIGNING_PRIVATE_KEY",
        "KEY_ID": "ZERO_SIGNING_KEY_ID",
    }

    def test_missing_optional_group_is_omitted(self):
        self.assertEqual(optional_runtime_secrets({}, self.KEYS, "Zero Signing"), {})

    def test_complete_optional_group_is_forwarded(self):
        secrets = {
            "ZERO_SIGNING_PRIVATE_KEY": "private-key",
            "ZERO_SIGNING_KEY_ID": "key-id",
        }
        self.assertEqual(
            optional_runtime_secrets(secrets, self.KEYS, "Zero Signing"),
            {"PRIVATE": "private-key", "KEY_ID": "key-id"},
        )

    def test_partial_optional_group_is_rejected(self):
        with self.assertRaisesRegex(SystemExit, "missing KEY_ID"):
            optional_runtime_secrets(
                {"ZERO_SIGNING_PRIVATE_KEY": "private-key"},
                self.KEYS,
                "Zero Signing",
            )


if __name__ == "__main__":
    unittest.main()
