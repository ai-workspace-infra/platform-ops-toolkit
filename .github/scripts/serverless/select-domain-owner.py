#!/usr/bin/env python3
"""Select a fixed declaration and publisher; no provider mutations."""
import json
import os
from pathlib import Path
import re
import subprocess


def select(config, environment, head):
    if not re.fullmatch(r'[0-9a-f]{40}', head):
        raise ValueError('Fixed GitOps revision required')
    if config.get('kind') != 'EdgeRoutingConfig' or config['metadata']['environment'] != environment:
        raise ValueError('Routing declaration environment mismatch')
    # All PROD gateway changes use its guarded entry, including older GitOps
    # snapshots selected before the GTM alias declaration is activated.
    guarded = environment == 'prod'
    return {'gitops_ref': head, 'guarded_api_gateway': str(guarded).lower()}


def main():
    config = json.loads(Path(os.environ['CLOUDFLARE_BOUNDARY_CONFIG']).read_text())
    head = subprocess.check_output(['git', '-C', os.environ['GITOPS_DIR'], 'rev-parse', 'HEAD'], text=True).strip()
    outputs = select(config, os.environ['REQUESTED_ENVIRONMENT'], head)
    with Path(os.environ['GITHUB_OUTPUT']).open('a') as handle:
        for key, value in outputs.items(): handle.write(f'{key}={value}\n')
    print('Declared API publisher selected; guarded gateway=' + outputs['guarded_api_gateway'])


if __name__ == '__main__': main()
