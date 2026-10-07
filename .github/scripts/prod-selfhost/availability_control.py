#!/usr/bin/env python3
"""Reuse the original resource receipt for read-only target availability."""
import json
import os
from pathlib import Path
import tempfile
import native_standby_control as base


def main():
    event = json.loads(Path(os.environ['GITHUB_EVENT_PATH']).read_text())
    inputs = event.get('inputs', {})
    base.require(inputs.get('operation') in ('deploy', 'deploy+migrate', 'native-availability'),
                 'availability requires an explicit deployment or availability operation')
    base.require(inputs.get('vault_env_path') == 'prod' and inputs.get('target_domains') == 'web-saas',
                 'availability is scoped to PROD Web SaaS')
    # Reuse immutable caller and target validation; deployment tags remain records.
    normalized = {**event, 'inputs': {**inputs, 'operation': 'native-standby', 'deploy_tag': '', 'dns_mode': 'none'}}
    with tempfile.TemporaryDirectory(dir=os.environ['RUNNER_TEMP']) as directory:
        path = Path(directory) / 'event.json'
        path.write_text(json.dumps(normalized))
        original = os.environ['GITHUB_EVENT_PATH']
        os.environ['GITHUB_EVENT_PATH'] = str(path)
        try:
            base.main()
        finally:
            os.environ['GITHUB_EVENT_PATH'] = original


if __name__ == '__main__':
    main()
