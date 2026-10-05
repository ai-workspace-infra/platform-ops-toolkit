#!/usr/bin/env python3
"""Freeze existing execution debt; new Toolkit code must remain control-plane-only."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess

def command_pattern(commands):
    # Match an invocation, not a receipt key such as running_digests/docker or
    # a routing value such as provisioner=terraform. This is a review aid,
    # not a complete shell/Python security parser.
    return (r'(?m)(?:^[ \t]*|[;&|][ \t]*|\$\()(?:(?:if|elif|then|do|while|until|!|exec|sudo|command|run_gcloud)[ \t]+)*'
            + r'(?:[A-Za-z_]\w*=(?:"[^"\n]*"|\x27[^\x27\n]*\x27|[^\s"\x27;]+)[ \t]+)*(?:' + commands + r')\s'
            + r'|[\[(]\s*[\"\x27](?:' + commands + r')[\"\x27]\s*,')


MARKERS = {
    'database_execution': command_pattern('pg_dump|pg_restore|psql'),
    'host_execution': command_pattern('ssh|sshpass|scp|ansible-playbook|ansible|docker|systemctl|sysctl|wg|apt-get'),
    'provider_execution': command_pattern('terraform|gcloud|wrangler|aws'),
}

# Only bounded read operations, not a filename/owner-label exemption. Other
# invocations in the very same source are still classified normally.
READ_ONLY_GATES = (
    r'\bgcloud\s+run\s+(?:services|revisions)\s+describe\b',
    r'\bdocker\s+buildx\s+imagetools\s+inspect\b',
    r'\baws\s+sts\s+get-caller-identity\b',
)
MUTATING_HTTP = r'(?:-X\s*|--request(?:=|\s+))[^\s]+|--data(?:-binary|-raw|-urlencode)?(?:=|\s)|(?:^|\s)-d(?:\s|[\"\x27])|--upload-file(?:=|\s)'
ASSIGNMENT = re.compile(r'''(?m)(?:^|\s)(?:readonly\s+|local\s+)?([A-Za-z_]\w*)=(?:"([^"\n]*)"|'([^'\n]*)'|([^\s;]+))''')
VARIABLE = re.compile(r'\$\{([A-Za-z_]\w*)\}|\$([A-Za-z_]\w*)')


def logical_source(source):
    return re.sub(r'\\\n\s*', ' ', '\n'.join(
        line for line in source.splitlines() if not line.lstrip().startswith('#')))


def control_url(value, assignments, seen=()):
    """Prove only a small set of control-plane endpoint shapes and aliases.

    A header or an unrelated Vault reference is never sufficient evidence.
    Ambiguous/reassigned/dynamic endpoints remain review candidates.
    """
    if re.match(r'^\$\{VAULT_ADDR(?:%/)?\}/v1/', value):
        return True
    if re.match(r'^\$\{?ACTIONS_ID_TOKEN_REQUEST_URL\}?(?:&|$)', value):
        return True
    if re.match(r'^\$\{ACCOUNTS_API_URL(?:%/)?\}/api/internal/overlay/networks/bootstrap$', value):
        return True
    match = VARIABLE.fullmatch(value)
    if match:
        name = match.group(1) or match.group(2)
        values = assignments.get(name, [])
        return bool(values) and name not in seen and all(
            control_url(item, assignments, (*seen, name)) for item in values)
    return False


def http_markers(source):
    assignments = {}
    for match in ASSIGNMENT.finditer(source):
        assignments.setdefault(match.group(1), []).append(next(
            group for group in match.groups()[1:] if group is not None))
    arrays = {name: body for name, body in re.findall(
        r'\b([A-Za-z_]\w*)=\(([^)]*)\)', source, re.S)}
    risky = False
    for match in re.finditer(r'\bcurl\s+([^\n;]*?)(?=\s+(?:&&|\|\|)|;|\n|$)', source):
        arguments = match.group(1)
        expanded = arguments
        for name, body in arrays.items():
            if re.search(r'\$\{' + re.escape(name) + r'\[@\]\}', arguments):
                expanded += ' ' + body
        if not re.search(MUTATING_HTTP, expanded):
            continue
        # GET/HEAD explicitly specified without a payload are non-mutating.
        methods = [item.strip('"\x27') for item in re.findall(
            r'(?:-X\s*|--request(?:=|\s+))([^\s]+)', expanded)]
        if (methods and all(item in {'GET', 'HEAD'} for item in methods)
                and not re.search(r'--data|--upload-file|(?:^|\s)-d(?:\s|[\"\x27])', expanded)):
            continue
        # The last quoted URL/alias must resolve to a known endpoint. Do not
        # whitelist a request merely because X-Vault-Token appears in headers.
        quoted = re.findall(r'''["']([^"']*)["']''', arguments)
        endpoints = [item for item in quoted if item.startswith(('http', '$'))]
        if not endpoints or not control_url(endpoints[-1], assignments):
            risky = True
    if not risky:
        return []
    if 'api.cloudflare.com/' in source or 'CLOUDFLARE_API_BASE' in source:
        return ['provider_execution']
    return ['http_execution_review']


def classify(source):
    source = logical_source(source)
    commands = source
    for pattern in READ_ONLY_GATES:
        commands = re.sub(pattern, 'toolkit_read_only_gate', commands)
    matched = {name for name, pattern in MARKERS.items() if re.search(pattern, commands)}
    # Follow simple shell command arrays/scalars only when invoked. An unused
    # array or a receipt field named ssh is not execution evidence.
    for name, body in re.findall(r'\b([A-Za-z_]\w*)=\(([^)]*)\)', commands, re.S):
        if re.search(r'\b(?:ssh|sshpass|scp|ansible-playbook|docker)\b', body) and re.search(
                r'\$\{' + re.escape(name) + r'\[@\]\}', commands):
            matched.add('host_execution')
        if re.search(r'\b(?:terraform|gcloud|aws|wrangler)\b', body) and re.search(
                r'\$\{' + re.escape(name) + r'\[@\]\}', commands):
            matched.add('provider_execution')
    for match in ASSIGNMENT.finditer(commands):
        value = next(group for group in match.groups()[1:] if group is not None)
        if value in {'ssh', 'scp', 'ansible-playbook', 'docker', 'gcloud', 'terraform', 'aws', 'wrangler'} and re.search(
                r'(?m)(?:^\s*|[;&|]\s*|\$\()[\"\x27]?\$(?:\{' + re.escape(match.group(1)) +
                r'\}|' + re.escape(match.group(1)) + r'\b)', commands):
            matched.add('host_execution' if value in {'ssh', 'scp', 'ansible-playbook', 'docker'} else 'provider_execution')
    matched.update(http_markers(source))
    return [name for name in (*MARKERS, 'http_execution_review') if name in matched]


def inferred_owner(markers):
    if any(item in markers for item in ('database_execution', 'host_execution')):
        return 'playbooks'
    if 'provider_execution' in markers:
        return 'iac_modules'
    return 'review_required'


def inventory(root):
    paths = subprocess.check_output(['git', '-C', str(root), 'ls-files', '.github/scripts'], text=True).splitlines()
    found = {}
    for relative in paths:
        path = root / relative
        if not path.is_file() or path.suffix not in {'.sh', '.py', '.rb'}:
            continue
        if 'tests' in path.parts or path.name.startswith('test_') or path.name.endswith('_test.sh'):
            continue
        matched = classify(path.read_text())
        if not matched:
            continue
        found[relative] = {'owner': inferred_owner(matched),
                           'markers': matched, 'sha256': hashlib.sha256(path.read_bytes()).hexdigest()}
    return found


def verify(root, registry):
    current = inventory(root)
    entries = registry.get('legacy_execution', {})
    errors = []
    # Freeze recorded bytes even if an edit removes the regex marker. Changes
    # cannot disappear from the guard just by changing invocation spelling.
    for path, entry in entries.items():
        existing = root / path
        if existing.is_file() and hashlib.sha256(existing.read_bytes()).hexdigest() != entry['sha256']:
            errors.append('legacy bytes changed; migrate instead of extending: ' + path)
    for path, entry in current.items():
        if path not in entries:
            errors.append('new execution logic must move to its owner: ' + path)
        elif entry != entries[path]:
            errors.append('legacy execution changed; migrate instead of extending: ' + path)
    if errors:
        raise SystemExit('\n'.join('::error::' + error for error in errors))
    print(f'Control-plane boundary verified; {len(current)} frozen legacy execution candidates remain (not fully migrated). Scanner hints are not owner approval or UAT evidence.')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--root', type=Path, default=Path.cwd())
    parser.add_argument('--inventory-only', action='store_true')
    args = parser.parse_args()
    root = args.root.resolve()
    if args.inventory_only:
        print(json.dumps({'schema': 1, 'policy': 'frozen-legacy-debt-not-an-exemption-for-new-code', 'legacy_execution': inventory(root)}, indent=2, sort_keys=True))
    else:
        verify(root, json.loads((root / 'scripts/ci/legacy-execution-inventory.json').read_text()))


if __name__ == '__main__':
    main()
