import importlib.util
import sys
import unittest
from pathlib import Path


SCRIPT_DIR = Path(__file__).resolve().parents[1] / "node_deploy"
sys.path.insert(0, str(SCRIPT_DIR))
SPEC = importlib.util.spec_from_file_location("prepare_known_hosts", SCRIPT_DIR / "prepare_known_hosts.py")
module = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(module)


class KnownHostPinTests(unittest.TestCase):
    def test_accepts_only_the_reviewed_key_for_exact_address(self):
        result = module.verify_scan("35.1.2.3", "abc=", "# banner\n35.1.2.3 ssh-ed25519 abc=\n")
        self.assertEqual(result, "35.1.2.3 ssh-ed25519 abc=")
        with self.assertRaises(ValueError):
            module.verify_scan("35.1.2.3", "abc=", "35.1.2.3 ssh-ed25519 other=\n")
        with self.assertRaises(ValueError):
            module.verify_scan("35.1.2.3", "abc=", "35.1.2.4 ssh-ed25519 abc=\n")


if __name__ == "__main__":
    unittest.main()
