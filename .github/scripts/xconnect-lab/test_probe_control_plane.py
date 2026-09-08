import importlib.util
from pathlib import Path
import unittest
from unittest.mock import MagicMock, patch

spec = importlib.util.spec_from_file_location('probe', Path(__file__).with_name('probe-control-plane.py'))
probe = importlib.util.module_from_spec(spec)
spec.loader.exec_module(probe)


class DeployedControlPlaneGuard(unittest.TestCase):
    def test_probe_identifies_itself_without_credentials(self):
        response = MagicMock()
        response.__enter__.return_value = response
        response.status = 401
        response.headers = {'X-Frontend-Route': 'ssr-console'}
        response.read.return_value = b'{"error":"unauthenticated"}'
        with patch.object(probe, 'urlopen', return_value=response) as request:
            probe.probe('https://console.example.test/api/xconnect-zero/overview', portal=True)
        sent = request.call_args.args[0]
        self.assertEqual(dict(sent.header_items()), {
            'Accept': 'application/json', 'User-agent': 'XConnect-UAT-Lab/1.0'})
        self.assertEqual(request.call_args.kwargs['timeout'], 15)
        self.assertEqual(sent.get_method(), 'GET')

    def test_real_bff_anonymous_response(self):
        probe.check_response(401, {'X-Frontend-Route': 'ssr-console'}, b'{"error":"unauthenticated"}', portal=True)

    def test_generic_api_401_is_not_bff_success(self):
        with self.assertRaises(ValueError):
            probe.check_response(401, {'X-Frontend-Route': 'api'}, b'{"error":"Unauthorized: Missing or invalid Bearer token"}', portal=True)

    def test_missing_bff_in_console_artifact(self):
        for status, body in [(404, b'not found'), (200, b'<html>'), (401, b'{"code":401}')]:
            with self.subTest(status=status), self.assertRaises(ValueError):
                probe.check_response(status, {'x-frontend-route': 'ssr-console'}, body, portal=True)

    def test_no_public_access_to_formal_api(self):
        probe.check_response(401, {}, b'', portal=False)
        for status in (200, 302, 404, 500):
            with self.subTest(status=status), self.assertRaises(ValueError):
                probe.check_response(status, {}, b'', portal=False)


if __name__ == '__main__':
    unittest.main()
