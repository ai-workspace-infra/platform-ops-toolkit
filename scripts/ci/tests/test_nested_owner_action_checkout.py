"""A nested Toolkit glue action cannot hide an unprepared owner dependency."""
import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import yaml

spec = importlib.util.spec_from_file_location('refs', Path(__file__).resolve().parents[1]/'workflow_script_refs_verify.py')
refs = importlib.util.module_from_spec(spec)
spec.loader.exec_module(refs)


class NestedOwnerCheckout(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        glue = self.root/'.github/actions/glue'
        glue.mkdir(parents=True)
        (glue/'action.yml').write_text(yaml.safe_dump({'runs': {'using':'composite', 'steps':[{'uses':'./iac_modules/.github/actions/auth-gcp-cloud'}]}}))
        owner = self.root/'iac/.github/actions/auth-gcp-cloud'
        owner.mkdir(parents=True)
        (owner/'action.yml').write_text('name: fixture\n')
        refs.violations.clear()
        refs.called_actions.clear()

    def check(self, checkout=None, call_if=None):
        steps = [] if checkout is None else [checkout]
        call = {'uses':'./.github/actions/glue'}
        if call_if: call['if'] = call_if
        steps.append(call)
        with patch.object(refs, 'REPO_ROOT', self.root):
            refs.walk_steps('caller', steps, {'iac_modules':self.root/'iac'})
        return refs.violations

    def checkout(self, **overrides):
        result = {'uses':'actions/checkout@v4', 'with':{'repository':'ai-workspace-infra/iac_modules', 'path':'iac_modules', 'ref':'a'*40}}
        result.update(overrides)
        return result

    def test_nested_owner_consumes_preceding_caller_checkout(self):
        self.assertEqual(self.check(self.checkout()), [])

    def test_missing_checkout_is_rejected_inside_glue(self):
        self.assertTrue(any('no preceding checkout' in v for v in self.check()))

    def test_conditional_checkout_cannot_back_unconditional_glue(self):
        self.assertTrue(any('conditional' in v for v in self.check(self.checkout(**{'if':'inputs.enabled'}))))

    def test_conditioned_glue_preserves_inherited_condition(self):
        self.assertEqual(self.check(self.checkout(**{'if':'inputs.enabled'}), 'inputs.enabled'), [])

    def test_owner_checkout_with_missing_ref_fails(self):
        checkout = self.checkout()
        del checkout['with']['ref']
        self.assertTrue(any('no explicit ref' in v for v in self.check(checkout)))


if __name__ == '__main__':
    unittest.main()
