"""Regression coverage for environment-specific Console DNS validation."""
import unittest

from validate_cloudflare_boundaries import validate_console_dns


class ConsoleDnsValidationTests(unittest.TestCase):
    def test_nonproduction_uses_its_own_canonical_host(self):
        for environment in ("uat", "sit"):
            target = f"console-serverless-{environment}.onwalk.net"
            validate_console_dns(environment, {f"console-{environment}.onwalk.net": target}, {"console_host": target})

    def test_production_record_cannot_satisfy_uat(self):
        with self.assertRaisesRegex(SystemExit, "console-uat.onwalk.net"):
            validate_console_dns("uat", {"console.svc.plus": "wrong"}, {"console_host": "wrong"})

    def test_missing_and_wrong_nonproduction_targets_fail(self):
        for records in ({}, {"console-uat.onwalk.net": "wrong"}):
            with self.assertRaises(SystemExit):
                validate_console_dns("uat", records, {"console_host": "console-serverless-uat.onwalk.net"})

    def test_production_requires_worker_alias_without_cname(self):
        config = {"console_aliases": ["console.svc.plus"]}
        validate_console_dns("prod", {}, config)
        with self.assertRaises(SystemExit):
            validate_console_dns("prod", {"console.svc.plus": "console-serverless-prod.svc.plus"}, config)
        with self.assertRaises(SystemExit):
            validate_console_dns("prod", {}, {})


if __name__ == "__main__":
    unittest.main()
