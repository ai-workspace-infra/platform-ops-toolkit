import re
from pathlib import Path
import unittest
import yaml

ROOT = Path(__file__).resolve().parents[2]

class UatDnsOwnerRouteTests(unittest.TestCase):
    def test_dns_owner_is_pinned_and_waits_for_acceptance(self):
        workflow = yaml.load((ROOT / '.github/workflows/selfhost-orchestrator.yml').read_text(), Loader=yaml.BaseLoader)
        job = workflow['jobs']['switch_dns']
        self.assertIn('accept_web_saas_upgrade', job['needs'])
        self.assertIn("needs.accept_web_saas_upgrade.result == 'success'", job['if'])
        checkout = next(s for s in job['steps'] if s.get('name') == 'Check out reviewed UAT DNS provider owner')
        self.assertEqual(checkout['with']['repository'], 'ai-workspace-infra/iac_modules')
        self.assertRegex(checkout['with']['ref'], r'^[0-9a-f]{40}$')
        run = next(s for s in job['steps'] if s.get('name') == 'Reconcile UAT DNS records')
        self.assertIn('iac-dns-owner/scripts/pipeline/cloudflare-uat-dns-reconcile.sh', run['run'])
        self.assertNotIn('.github/scripts/platform-ops/dns', run['run'])
