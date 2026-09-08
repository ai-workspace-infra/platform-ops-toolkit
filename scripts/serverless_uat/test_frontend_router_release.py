"""Offline CD contract: immutable project release, checksums, no source build."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / 'scripts/serverless_uat/deploy_frontend_router.sh'


class RouterReleaseDeployment(unittest.TestCase):
    def run_case(self, mode='', tag='uat-daily-build-2026.09.08-r19'):
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory)
            bin_dir = folder / 'bin'
            repo = folder / 'router'
            bin_dir.mkdir()
            (repo / 'scripts').mkdir(parents=True)
            config = folder / 'gitops.json'
            config.write_text('{}')
            assets = folder / 'assets'
            assets.mkdir()
            metadata = {'schema_version': 1, 'tag': tag, 'source_sha': 'a' * 40}
            if mode == 'wrong_tag':
                metadata['tag'] = 'different-tag'
            if mode == 'wrong_source':
                metadata['source_sha'] = 'b' * 40
            (assets / 'frontend-router-worker.js').write_text('export default {};\n')
            (assets / 'release-metadata.json').write_text(json.dumps(metadata))
            sums = ''.join(f'{hashlib.sha256((assets / name).read_bytes()).hexdigest()}  {name}\n'
                           for name in ('frontend-router-worker.js', 'release-metadata.json'))
            if mode == 'missing_metadata_checksum':
                sums = sums.splitlines()[0] + '\n'
            (assets / 'SHA256SUMS').write_text(sums)
            if mode == 'corrupt':
                (assets / 'frontend-router-worker.js').write_text('corrupted\n')
            commands = {
                'gh': 'while [ "$1" != --dir ]; do shift; done; cp "$ASSETS/"* "$2/"',
                'git': 'printf "%s\\n" aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
                'npm': '[ "$*" = ci ] || exit 99',
            }
            for name, body in commands.items():
                file = bin_dir / name
                file.write_text('#!/bin/sh\nset -eu\n' + body + '\n')
                file.chmod(0o755)
            deploy = repo / 'scripts/deploy_from_gitops.sh'
            deploy.write_text('#!/bin/sh\nset -eu\ntest -f "$FRONTEND_ROUTER_ARTIFACT_FILE"\nprintf "DEPLOYED_PREBUILT\\n"\n')
            deploy.chmod(0o755)
            env = {**os.environ, 'PATH': str(bin_dir) + os.pathsep + os.environ['PATH'],
                   'FRONTEND_ROUTER_DIR': str(repo), 'CLOUDFLARE_BOUNDARY_CONFIG': str(config),
                   'FRONTEND_ROUTER_RELEASE_TAG': tag, 'RUNNER_TEMP': str(folder), 'ASSETS': str(assets)}
            return subprocess.run(['bash', str(SCRIPT)], env=env, capture_output=True, text=True)

    def test_valid_prebuilt_release(self):
        result = self.run_case()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('DEPLOYED_PREBUILT', result.stdout)

    def test_fail_before_deploy_on_unverified_release(self):
        for mode in ('wrong_tag', 'wrong_source', 'missing_metadata_checksum', 'corrupt'):
            with self.subTest(mode=mode):
                result = self.run_case(mode)
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn('DEPLOYED_PREBUILT', result.stdout)

    def test_floating_ref_rejected(self):
        result = self.run_case(tag='main')
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn('DEPLOYED_PREBUILT', result.stdout)


if __name__ == '__main__':
    unittest.main()
