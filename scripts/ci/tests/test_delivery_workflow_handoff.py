"""Prove Toolkit owns delivery jobs while fixed IaC actions own provider queries."""
from pathlib import Path
import re
import unittest
import yaml

ROOT = Path(__file__).resolve().parents[3]


class WorkflowHandoff(unittest.TestCase):
    def load(self, filename):
        return yaml.safe_load((ROOT/'.github/workflows'/filename).read_text())

    def test_domains_request_precedes_vault_and_receipt_follows_execution(self):
        steps = self.load('iac-cloudflare-serverless-domains.yaml')['jobs']['reconcile']['steps']
        position = lambda fragment: next(i for i, step in enumerate(steps) if fragment in step.get('uses', ''))
        self.assertLess(position('serverless-domains-context'), position('hashicorp/vault-action'))
        self.assertLess(position('hashicorp/vault-action'), position('cloudflare-serverless-domains'))
        receipt = next(i for i,s in enumerate(steps) if s.get('with',{}).get('phase') == 'receipt')
        self.assertLess(position('cloudflare-serverless-domains'), receipt)
        self.assertEqual(steps[-1]['with']['if-no-files-found'], 'error')

    def test_moved_deliveries_pin_owner_and_preserve_approvals(self):
        for filename in ['iac-cloudflare-serverless-domains.yaml', 'iac-akamai-state-preflight.yaml']:
            with self.subTest(filename=filename):
                document = self.load(filename)
                for job in document['jobs'].values():
                    self.assertIn('environment', job)
                    owner = [step for step in job['steps'] if step.get('with',{}).get('repository') == 'ai-workspace-infra/iac_modules']
                    self.assertEqual(len(owner), 1)
                    self.assertRegex(owner[0]['with']['ref'], r'^[0-9a-f]{40}$')
                self.assertEqual(document['concurrency']['cancel-in-progress'], False)

    def test_callers_have_no_iac_delivery_workflow_dependency(self):
        for filename, job, wrapper in [('serverless-orchestrator.yml', 'serverless_domains_provider', 'iac-cloudflare-serverless-domains.yaml'),
                                      ('environment-data-operations.yml', 'akamai_preflight', 'iac-akamai-state-preflight.yaml')]:
            document = self.load(filename)
            self.assertEqual(document['jobs'][job]['uses'], './.github/workflows/'+wrapper)

    def test_new_workflow_claims_are_exact_and_preserve_rollback(self):
        import json
        for environment in ['sit', 'uat', 'prod']:
            role = json.loads((ROOT/f'scripts/vault/roles/github-actions-platform-ops-toolkit-{environment}.json').read_text())
            claims = role['bound_claims']['job_workflow_ref']
            prefix = 'ai-workspace-infra/platform-ops-toolkit/.github/workflows/iac-cloudflare-serverless-domains.yaml@'
            self.assertEqual([c.removeprefix(prefix) for c in claims if c.startswith(prefix)], role['bound_claims']['ref'])
            self.assertNotIn(prefix + '*', claims)
            self.assertTrue(any('iac_modules/.github/workflows/cloudflare-serverless-domains.yml@' in v for v in claims))
            if environment == 'prod':
                from fnmatch import fnmatchcase
                selected = [c for c in claims if c.startswith(prefix)]
                self.assertTrue(any(fnmatchcase(prefix + 'refs/tags/v2026.10.07-r1', c) for c in selected))
                for ref in ('refs/heads/main', 'refs/heads/feature/demo', 'refs/tags/daily-build-2026.10.07'):
                    self.assertFalse(any(fnmatchcase(prefix + ref, c) for c in selected))
        template = json.loads((ROOT/'scripts/vault/templates/akamai-oidc-role-uat.json.tmpl').read_text())
        self.assertIn('ai-workspace-infra/platform-ops-toolkit/.github/workflows/iac-akamai-state-preflight.yaml@refs/heads/main', template['bound_claims']['job_workflow_ref'])


if __name__ == '__main__':
    unittest.main()
