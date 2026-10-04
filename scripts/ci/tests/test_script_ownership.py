"""Positive and falsifiable negative cases without provider or host access."""
import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'script_ownership_verify.py'
spec = importlib.util.spec_from_file_location('ownership', SCRIPT)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class OwnershipTests(unittest.TestCase):
    def fixture(self, directory, content):
        root = Path(directory)
        path = root / '.github/scripts/legacy/example.sh'
        path.parent.mkdir(parents=True)
        path.write_text(content)
        subprocess.run(['git', 'init', '-q', str(root)], check=True)
        subprocess.run(['git', '-C', str(root), 'add', '.'], check=True)
        return root, path

    def test_new_database_and_host_execution_rejected(self):
        for content in ('pg_dump account\n', 'ssh target restart\n', 'gcloud run deploy service\n'):
            with tempfile.TemporaryDirectory() as directory:
                root, _ = self.fixture(directory, content)
                with self.assertRaises(SystemExit):
                    module.verify(root, {'legacy_execution': {}})

    def test_frozen_copy_cannot_change_and_can_be_removed(self):
        with tempfile.TemporaryDirectory() as directory:
            root, path = self.fixture(directory, 'pg_dump account\n')
            registry = {'legacy_execution': module.inventory(root)}
            module.verify(root, registry)
            path.write_text('pg_dump other_database\n')
            with self.assertRaises(SystemExit):
                module.verify(root, registry)
            path.unlink()
            module.verify(root, registry)

    def test_thin_dispatch_is_control_plane(self):
        with tempfile.TemporaryDirectory() as directory:
            root, _ = self.fixture(directory, 'gh workflow run environment-data-operations.yml\n')
            module.verify(root, {'legacy_execution': {}})


if __name__ == '__main__':
    unittest.main()
