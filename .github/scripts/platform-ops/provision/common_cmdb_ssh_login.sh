# shellcheck shell=bash
# Resolve how to SSH into a CMDB host.
#
# GCP OS Login and AWS hosts log in as a non-root user with passwordless sudo
# (setup-deployment-runner already relies on this), so root-only remote work
# runs through `sudo -n`. Hosts without an ansible_user keep the root login.
#
# Usage: cmdb_ssh_login <cmdb_file> <host>  — sets ssh_user and sudo_prefix.
cmdb_ssh_login() {
  ssh_user="$(jq -r --arg host "$2" '.[$host].ansible_user // "root"' "$1")"
  if [[ ! "${ssh_user}" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then
    echo "::error::Invalid SSH user for $2 in $1." >&2
    return 2
  fi
  sudo_prefix=''
  if [[ "${ssh_user}" != root ]]; then
    sudo_prefix='sudo -n '
  fi
}
