#!/usr/bin/env bash
set -euo pipefail

# The playbooks use community.hashi_vault.vault_write on the controller for
# generated credentials/UUID persistence.  The collection is present in the
# runner image, but its Python dependency is not guaranteed to be.  Install it
# together with Ansible so delegated localhost tasks do not fail late in the
# deployment gate.
pip install --quiet ansible hvac
