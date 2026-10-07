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

    def node_fixture(self, directory, files):
        root = Path(directory)
        for name, content in files.items():
            path = root / 'scripts/node_deploy' / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(content)
        subprocess.run(['git', 'init', '-q', str(root)], check=True)
        subprocess.run(['git', '-C', str(root), 'add', '.'], check=True)
        return root

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

    def test_marker_removal_does_not_bypass_frozen_sha(self):
        with tempfile.TemporaryDirectory() as directory:
            root, path = self.fixture(directory, 'ssh host restart\n')
            registry = {'legacy_execution': module.inventory(root)}
            path.write_text('echo "no execution marker remains"\n')
            with self.assertRaisesRegex(SystemExit, 'legacy bytes changed'):
                module.verify(root, registry)

    def test_many_quoted_assignments_do_not_backtrack_unboundedly(self):
        with tempfile.TemporaryDirectory() as directory:
            source = ' '.join('VAR' + str(index) + '=\"value\"' for index in range(50)) + ' echo done\n'
            root, _ = self.fixture(directory, source)
            result = subprocess.run(['python3', str(SCRIPT), '--root', str(root), '--inventory-only'],
                                    capture_output=True, text=True, timeout=5, check=True)
            self.assertIn('"legacy_execution": {}', result.stdout)

    def test_dynamic_host_arrays_and_scalars(self):
        for source in (
            'ssh_command=(ssh)\n"${ssh_command[@]}" host restart\n',
            'gateway_ssh=(sshpass -e ssh)\n"${gateway_ssh[@]}" host restart\n',
            'SSH_CMD="ssh"\n"$SSH_CMD" host restart\n',
            'SSH=(ssh -i key)\ntimeout 30 "${SSH[@]}" host probe\n',
            'if ssh host true; then echo ready; fi\n',
            'systemctl daemon-reload\n',
            'handshakes=$(wg show interface latest-handshakes)\n',
        ):
            with self.subTest(source=source):
                self.assertIn('host_execution', module.classify(source))

    def test_uninvoked_array_and_receipt_not_execution(self):
        for source in ('SSH=(ssh)\necho configured\n', 'receipt="running_digests/docker"\n', '# ssh target restart\n'):
            self.assertEqual([], module.classify(source))

    def test_provider_environment_assignments_and_arrays(self):
        for source in (
            'AWS_ACCESS_KEY_ID="$state" AWS_REGION="$region" aws s3api put-object --bucket bucket\n',
            'tool=(gcloud)\n"${tool[@]}" secrets create name\n',
            'PROVIDER="terraform"\n"$PROVIDER" apply\n',
            'args = ["gcloud", "run", "deploy", "service"]\n',
        ):
            self.assertIn('provider_execution', module.classify(source))

    def test_root_python_subprocess_ssh_and_provider_are_rejected(self):
        for command, marker in (('ssh', 'host_execution'), ('gcloud', 'provider_execution')):
            with self.subTest(command=command), tempfile.TemporaryDirectory() as directory:
                root = self.node_fixture(directory, {
                    'new_executor.py': f'import subprocess\nsubprocess.run(["{command}", "target"], check=True)\n'
                })
                self.assertIn(marker, module.inventory(root)['scripts/node_deploy/new_executor.py']['markers'])
                with self.assertRaises(SystemExit):
                    module.verify(root, {'legacy_execution': {}})

    def test_imported_execution_wrapper_inherits_owner_marker(self):
        with tempfile.TemporaryDirectory() as directory:
            root = self.node_fixture(directory, {
                'executor.py': 'import subprocess\ndef execute():\n    subprocess.run(["ssh", "target", "true"], check=True)\n',
                'wrapper.py': 'from executor import execute\ndef main():\n    execute()\n',
            })
            found = module.inventory(root)
            self.assertIn('host_execution', found['scripts/node_deploy/executor.py']['markers'])
            self.assertIn('host_execution', found['scripts/node_deploy/wrapper.py']['markers'])

    def test_sourced_shell_execution_wrapper_inherits_owner_marker(self):
        with tempfile.TemporaryDirectory() as directory:
            root = self.node_fixture(directory, {
                'executor.sh': 'ssh target true\n',
                'wrapper.sh': 'source executor.sh\necho dispatched\n',
            })
            found = module.inventory(root)
            self.assertIn('host_execution', found['scripts/node_deploy/wrapper.sh']['markers'])

    def test_frozen_node_executor_bytes_cannot_change(self):
        with tempfile.TemporaryDirectory() as directory:
            root = self.node_fixture(directory, {
                'executor.py': 'import subprocess\nsubprocess.run(["ssh", "target", "true"], check=True)\n'
            })
            registry = {'legacy_execution': module.inventory(root)}
            module.verify(root, registry)
            (root / 'scripts/node_deploy/executor.py').write_text('print("marker removed")\n')
            with self.assertRaisesRegex(SystemExit, 'legacy bytes changed'):
                module.verify(root, registry)

    def test_bounded_readonly_release_gates(self):
        source = '''service=$(gcloud run services describe service --format=json)
revision=$(gcloud run revisions describe revision --format=json)
raw=$(docker buildx imagetools inspect --raw image@digest)
account=$(aws sts get-caller-identity --query Account)
'''
        self.assertEqual([], module.classify(source))
        self.assertIn('provider_execution', module.classify(source + 'gcloud run deploy service\n'))
        self.assertIn('host_execution', module.classify(source + 'docker run image\n'))

    def test_vault_requests_are_control_plane_not_provider(self):
        for source in (
            'URL="${VAULT_ADDR}/v1/kv/data/${ENV}/databases"\ncurl -X POST -d "$PAYLOAD" "$URL"\n',
            'URL="${VAULT_ADDR}/v1/kv/data/${ENV}/agent-proxy"\ncurl -X POST "$URL"\n',
            'curl --data-binary "@payload" "${VAULT_ADDR%/}/v1/auth/jwt/login"\n',
            'oidc_url="${ACTIONS_ID_TOKEN_REQUEST_URL}&audience=vault"\ncurl --request GET "$oidc_url"\n',
        ):
            self.assertEqual([], module.classify(source))

    def test_accounts_bootstrap_is_playbooks_http_debt(self):
        source = 'curl --data-binary "@invite" "${ACCOUNTS_API_URL%/}/api/internal/overlay/networks/bootstrap"\n'
        markers = module.classify(source)
        self.assertIn('service_execution', markers)
        self.assertIn('http_execution_review', markers)
        self.assertEqual('playbooks', module.inferred_owner(markers))

    def test_vault_header_or_other_request_never_grants_exemption(self):
        for source in (
            'curl -X POST -H "X-Vault-Token: $TOKEN" "https://unreviewed.example/mutate"\n',
            'URL="${VAULT_ADDR}/v1/auth/jwt/login"\nURL="https://unreviewed.example/mutate"\ncurl -X POST "$URL"\n',
            'URL="${VAULT_ADDR}/v1/auth/jwt/login"\ncurl -X POST "$URL"; curl -X POST "https://unreviewed.example/mutate"\n',
            'curl --request GET "https://example/read" && curl -X POST "https://example/write"\n',
            'URL="${VAULT_ADDR}/v1/auth/jwt/login"\ncurl -X POST "${URL:-https://example/write}"\n',
        ):
            self.assertIn('http_execution_review', module.classify(source))

    def test_dynamic_cloudflare_http_and_payloads_are_detected(self):
        for source in (
            'API_BASE="https://api.cloudflare.com/client/v4"\ncurl --request "$method" "$url"\n',
            'CLOUDFLARE_API_BASE="https://api.cloudflare.com/client/v4"\ncurl_args=(--request "${method}")\ncurl "${curl_args[@]}" "${url}"\n',
            'curl --request=PUT --data @file "https://api.cloudflare.com/client/v4/zones/zone/dns_records/id"\n',
            'curl -d "{json}" "https://api.cloudflare.com/client/v4/zones/zone/dns_records"\n',
        ):
            self.assertIn('provider_execution', module.classify(source))

    def test_http_mutation_unknown_owner_requires_review(self):
        for source in ('curl --request "$method" "$url"\n', 'curl --upload-file file "https://example/upload"\n'):
            markers = module.classify(source)
            self.assertIn('http_execution_review', markers)
            self.assertEqual('review_required', module.inferred_owner(markers))
        self.assertEqual([], module.classify('curl --request GET "https://api.cloudflare.com/client/v4/zones"\n'))
        self.assertIn('provider_execution', module.classify('curl -X GET -X DELETE "https://api.cloudflare.com/client/v4/zones/id"\n'))

    def test_owner_is_not_inferred_from_directory(self):
        with tempfile.TemporaryDirectory() as directory:
            root, path = self.fixture(directory, 'gcloud secrets versions add secret --data-file=-\n')
            serverless = root / '.github/scripts/serverless/smtp.sh'
            serverless.parent.mkdir()
            path.rename(serverless)
            subprocess.run(['git', '-C', str(root), 'add', '-A'], check=True)
            self.assertEqual('iac_modules', module.inventory(root)[str(serverless.relative_to(root))]['owner'])

    def test_live_repository_contract_candidates_and_control_plane(self):
        root = SCRIPT.parents[2]
        found = module.inventory(root)
        for relative in (
            'platform-ops/deploy/platform-ops_deploy_base_restore-caddy-certs.sh',
            'platform-ops/dns/platform-ops_sit_all_in_one_dns_reconcile.sh',
            'xconnect-lab/reconcile-gateway-dns.sh',
            'xconnect-lab/lease.sh',
            'xconnect-lab/gateway.sh',
        ):
            self.assertIn('.github/scripts/' + relative, found)
        for relative in (
            'auto_migration.py', 'prepare_known_hosts.py', 'run_stage.sh',
            'verify_vault_stage.py', 'xconnect_stage.py',
        ):
            self.assertIn('scripts/node_deploy/' + relative, found)
            self.assertEqual(found['scripts/node_deploy/' + relative]['status'], 'pending-owner-uat')
        self.assertEqual(found['.github/scripts/xconnect-network/bootstrap.sh']['owner'], 'playbooks')
        self.assertFalse((root / '.github/scripts/platform-ops/dns/platform-ops_uat_dns_reconcile.sh').exists())
        for relative in (
            'platform-ops/provision/platform-ops_provision_initialize-agent-proxy-credentials.sh',
            'platform-ops/provision/platform-ops_provision_initialize-databases-credentials.sh',
            'serverless/verify_cloud_run_image_digest.sh',
        ):
            self.assertNotIn('.github/scripts/' + relative, found)


if __name__ == '__main__':
    unittest.main()
