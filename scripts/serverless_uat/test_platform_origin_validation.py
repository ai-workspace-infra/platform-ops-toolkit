"""Regression coverage for public marketing platform origins."""
import unittest

from validate_cloudflare_boundaries import validate_platform_origin


class PlatformOriginValidationTests(unittest.TestCase):
    def test_production_accepts_platform_service_origin(self):
        validate_platform_origin("prod", "xworktech.com", {"platform_origin": "https://svc.plus"})

    def test_production_accepts_company_marketing_origin(self):
        validate_platform_origin("prod", "xworktech.com", {"platform_origin": "https://xworktech.com"})

    def test_production_rejects_unapproved_origin(self):
        with self.assertRaisesRegex(SystemExit, "must be one of"):
            validate_platform_origin("prod", "xworktech.com", {"platform_origin": "https://console.svc.plus"})

    def test_nonproduction_keeps_environment_console_origin(self):
        validate_platform_origin("uat", "onwalk.net", {"platform_origin": "https://console.onwalk.net"})
        with self.assertRaises(SystemExit):
            validate_platform_origin("uat", "onwalk.net", {"platform_origin": "https://xworktech.com"})


if __name__ == "__main__":
    unittest.main()
