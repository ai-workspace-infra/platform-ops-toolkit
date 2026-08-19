#!/usr/bin/env bash
set -euo pipefail

if command -v stunnel >/dev/null 2>&1; then
  exit 0
fi

sudo apt-get update -qq
sudo apt-get install --yes --no-install-recommends stunnel4
