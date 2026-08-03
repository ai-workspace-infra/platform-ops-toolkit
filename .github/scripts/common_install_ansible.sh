#!/usr/bin/env bash
set -euo pipefail

# The playbooks use community.hashi_vault.vault_write on the controller for
# generated credentials/UUID persistence.  The collection is present in the
# runner image, but its Python dependency is not guaranteed to be.  Install it
# together with Ansible so delegated localhost tasks do not fail late in the
# deployment gate.
#
# `ansible-playbook` may execute delegated localhost modules with the runner's
# system interpreter (/usr/bin/python3), while `pip` can resolve to the
# hosted-toolcache interpreter.  Install hvac through both entry points and
# assert the interpreter used by localhost can import it before any playbook
# starts.  The break-system-packages flag is required on Ubuntu 24.04's
# externally-managed system Python and only affects this ephemeral runner.
pip install --quiet ansible hvac
python3 -m pip install --quiet --break-system-packages hvac
python3 -c 'import hvac'
