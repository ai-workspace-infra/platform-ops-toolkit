import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
import yaml

ROOT = Path(__file__).resolve().parents[3]
RENDERER = ROOT / '.github/actions/gitops-yaml-json/render.rb'

class GitOpsYamlJsonTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.source = self.root / 'declaration.yaml'
        self.source.write_text('kind: Test\nspec:\n  enabled: true\n  account: "000123"\n  count: 24\n  items: [one, two]\n')
        self.output = self.root / 'derived.json'

    def render(self, source=None, output=None):
        return subprocess.run(['ruby', str(RENDERER)], capture_output=True, text=True,
          env={**os.environ, 'DECLARATION_SOURCE': str(source or self.source),
               'DECLARATION_OUTPUT': str(output or self.output), 'RUNNER_TEMP': str(self.root)})

    def test_preserves_types_and_source(self):
        before = self.source.read_bytes()
        result = self.render()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(self.output.read_text()), yaml.safe_load(before))
        self.assertEqual(self.source.read_bytes(), before)
        self.assertEqual(self.output.stat().st_mode & 0o777, 0o600)

    def test_reject_json_source(self):
        other = self.root / 'source.json'; other.write_text('{}')
        self.assertNotEqual(self.render(source=other).returncode, 0)
        self.assertFalse(self.output.exists())

    def test_reject_output_outside_temp(self):
        with tempfile.TemporaryDirectory() as other:
            output = Path(other) / 'derived.json'
            self.assertNotEqual(self.render(output=output).returncode, 0)
            self.assertFalse(output.exists())

    def test_reject_output_symlink(self):
        self.output.symlink_to(self.source)
        before = self.source.read_bytes()
        self.assertNotEqual(self.render().returncode, 0)
        self.assertEqual(self.source.read_bytes(), before)

    def test_reject_non_mapping(self):
        self.source.write_text('[one, two]\n')
        self.assertNotEqual(self.render().returncode, 0)

    def test_current_consumer_source_paths_are_yaml(self):
        for name in ('hybrid-orchestrator.yml','selfhost-orchestrator.yml','serverless-orchestrator.yml',
                     'aws-oidc-bootstrap.yml','prod-agent-proxy-diagnostics.yml'):
            text = (ROOT / '.github/workflows' / name).read_text()
            self.assertNotIn('/aws/github-actions-oidc.json', text, name)
            self.assertNotIn('/hybrid/resource-matrix.json', text, name)
            self.assertNotIn('/oauth/github.json', text, name)
        hybrid = (ROOT / '.github/workflows/hybrid-orchestrator.yml').read_text()
        self.assertIn('MATRIX_FILE: ${{ runner.temp }}/hybrid-resource-matrix.json', hybrid)
        serverless = (ROOT / '.github/workflows/serverless-orchestrator.yml').read_text()
        self.assertIn('GITOPS_OAUTH_GITHUB_CONFIG: ${{ runner.temp }}/accounts-github-oauth.json', serverless)

if __name__ == '__main__': unittest.main()
