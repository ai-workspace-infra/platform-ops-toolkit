#!/usr/bin/env bash
# Runs on the existing vault.svc.plus host (as root, via the pinned SSH channel)
# to move its Vault from local PostgreSQL storage to single-node Raft in place.
#
#   plan     NODE_ID OVERLAY_IP IFACE          report only, change nothing
#   apply    NODE_ID OVERLAY_IP IFACE CONFIRM  back up, stop Vault, migrate, guard ports
#   rollback                        CONFIRM    restore the PostgreSQL-backed Vault
#   retire                          CONFIRM    stop and disable Vault after remove-peer
#
# Only Vault and its own storage are touched: PostgreSQL is read once through
# 127.0.0.1 and never restarted, reconfigured, or written. The Raft service
# itself is started afterwards by the reviewed deploy_vault_single_raft.yml.
# No unseal key, root token, or database password is printed.
set -euo pipefail
umask 077

readonly CONFIG_DIR=/etc/vault.d
readonly CONFIG="${CONFIG_DIR}/vault.hcl"
readonly UNIT=/etc/systemd/system/vault.service
readonly DATA_DIR=/opt/vault/data
readonly BACKUP_DIR=/var/backups/vault-migration
readonly PG_PASSWORD_FILE=/root/.ai_workspace_vault_pg_password
readonly GUARD_TABLE=vault_port_guard
readonly GUARD_FILE=/etc/vault-port-guard.nft
readonly GUARD_UNIT=/etc/systemd/system/vault-port-guard.service
readonly PG_CONTAINER=postgresql

die() { echo "legacy-convert: $*" >&2; exit 1; }
say() { echo "legacy-convert: $*"; }

[[ "$(id -u)" == 0 ]] || die "must run as root"
mode="${1:-}"
shift || true

require_confirm() {
  [[ "$1" == "$2" ]] || die "refusing to run without confirm=$2"
}

pg_mode() { grep -Eq '^[[:space:]]*storage[[:space:]]+"postgresql"' "${CONFIG}"; }
raft_mode() { grep -Eq '^[[:space:]]*storage[[:space:]]+"raft"' "${CONFIG}"; }
data_empty() { [[ ! -d "${DATA_DIR}" ]] || [[ -z "$(ls -A "${DATA_DIR}")" ]]; }

check_args() {
  [[ "${node_id}" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]{0,62}$ ]] || die "invalid node id"
  [[ "${overlay_ip}" =~ ^(10|172|192)\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "overlay address must be private IPv4"
  [[ "${iface}" =~ ^[A-Za-z0-9_.-]{1,15}$ ]] || die "invalid overlay interface name"
}

pg_dump_vault() {
  local password="$1" destination="$2"
  if command -v pg_dump >/dev/null 2>&1; then
    PGPASSWORD="${password}" pg_dump -h 127.0.0.1 -U vault_storage -Fc vault_storage >"${destination}"
  elif command -v docker >/dev/null 2>&1 && docker ps --format '{{.Names}}' | grep -qx "${PG_CONTAINER}"; then
    PGPASSWORD="${password}" docker exec -e PGPASSWORD -i "${PG_CONTAINER}" \
      pg_dump -h 127.0.0.1 -U vault_storage -Fc vault_storage >"${destination}"
  else
    die "no pg_dump on the host or in the ${PG_CONTAINER} container"
  fi
  [[ -s "${destination}" ]] || die "PostgreSQL backup is empty"
}

install_port_guard() {
  command -v nft >/dev/null 2>&1 || die "nftables (nft) is required to keep 8200/8201 off the public Internet"
  cat >"${GUARD_FILE}" <<EOF
table inet ${GUARD_TABLE}
delete table inet ${GUARD_TABLE}
table inet ${GUARD_TABLE} {
  chain input {
    type filter hook input priority -10; policy accept;
    iifname "lo" accept
    iifname "${iface}" tcp dport { 8200, 8201 } accept
    tcp dport { 8200, 8201 } drop
  }
}
EOF
  chmod 0600 "${GUARD_FILE}"
  cat >"${GUARD_UNIT}" <<EOF
[Unit]
Description=Keep Vault API and Raft ports on loopback and the XConnect overlay
Before=vault.service
Wants=network-pre.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/sbin/nft -f ${GUARD_FILE}

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now vault-port-guard.service >/dev/null
  nft list table inet "${GUARD_TABLE}" >/dev/null || die "port guard did not load"
}

case "${mode}" in
  plan|apply)
    node_id="${1:-}"; overlay_ip="${2:-}"; iface="${3:-}"; confirm="${4:-}"
    check_args
    [[ -f "${CONFIG}" ]] || die "${CONFIG} not found"
    command -v vault >/dev/null 2>&1 || die "vault binary not found"
    if raft_mode; then
      say "already Raft; nothing to convert"
      exit 0
    fi
    pg_mode || die "existing Vault is neither PostgreSQL- nor Raft-backed"
    grep -q '@127\.0\.0\.1:' "${CONFIG}" || die "PostgreSQL storage is not local; refusing"
    [[ -s "${PG_PASSWORD_FILE}" ]] || die "local Vault PostgreSQL password file is missing"
    data_empty || die "${DATA_DIR} is not empty; refusing to overwrite Raft data"
    free_mb="$(df -Pm / | awk 'NR==2 {print $4}')"
    (( free_mb >= 1024 )) || die "less than 1 GiB free"
    command -v nft >/dev/null 2>&1 || die "nftables (nft) is required"
    say "plan: back up vault_storage, stop Vault, migrate PostgreSQL -> Raft at ${DATA_DIR} as ${node_id}, guard 8200/8201 to lo and ${iface}"
    [[ "${mode}" == apply ]] || exit 0

    require_confirm "${confirm}" CONVERT-VAULT-TO-RAFT
    stamp="$(date -u +%Y%m%dT%H%M%SZ)"
    install -d -m 700 "${BACKUP_DIR}"
    cp -p "${CONFIG}" "${BACKUP_DIR}/vault.hcl.postgresql-${stamp}"
    [[ -f "${UNIT}" ]] && cp -p "${UNIT}" "${BACKUP_DIR}/vault.service.postgresql-${stamp}"
    password="$(<"${PG_PASSWORD_FILE}")"

    say "stopping Vault (downtime starts)"
    started="$(date +%s)"
    systemctl stop vault
    systemctl is-active --quiet vault && die "Vault is still running"

    dump="${BACKUP_DIR}/vault_storage-${stamp}.dump"
    pg_dump_vault "${password}" "${dump}"
    sha256sum "${dump}" >"${dump}.sha256"
    say "backup written: ${dump} ($(du -h "${dump}" | cut -f1))"

    migrate_config="$(mktemp /root/vault-migrate.XXXXXX.hcl)"
    trap 'shred -u "${migrate_config}" 2>/dev/null || rm -f "${migrate_config}"' EXIT
    cat >"${migrate_config}" <<EOF
storage_source "postgresql" {
  connection_url = "postgres://vault_storage:${password}@127.0.0.1:5432/vault_storage?sslmode=disable"
}
storage_destination "raft" {
  path    = "${DATA_DIR}"
  node_id = "${node_id}"
}
cluster_addr = "https://${overlay_ip}:8201"
EOF
    install -d -m 700 "${DATA_DIR}"
    if ! vault operator migrate -config="${migrate_config}"; then
      say "migration failed; restarting the unchanged PostgreSQL-backed Vault"
      rm -rf "${DATA_DIR:?}"/*
      systemctl start vault
      die "vault operator migrate failed; the PostgreSQL data was only read"
    fi
    install_port_guard
    echo "${stamp}" >"${BACKUP_DIR}/converted"
    say "migrated in $(( $(date +%s) - started ))s; the Raft service is started by the playbook next"
    ;;

  rollback)
    require_confirm "${1:-}" ROLLBACK-VAULT-TO-POSTGRESQL
    backup="$(ls -1t "${BACKUP_DIR}"/vault.hcl.postgresql-* 2>/dev/null | head -n 1)"
    [[ -n "${backup}" ]] || die "no PostgreSQL configuration backup to restore"
    stamp="${backup##*-}"
    say "restoring PostgreSQL-backed Vault from ${backup}; writes made to Raft since then are not carried back"
    systemctl stop vault || true
    cp -p "${backup}" "${CONFIG}"
    [[ -f "${BACKUP_DIR}/vault.service.postgresql-${stamp}" ]] && cp -p "${BACKUP_DIR}/vault.service.postgresql-${stamp}" "${UNIT}"
    if [[ -d "${DATA_DIR}" ]] && ! data_empty; then
      mv "${DATA_DIR}" "${DATA_DIR}.rollback-$(date -u +%Y%m%dT%H%M%SZ)"
    fi
    systemctl daemon-reload
    systemctl start vault
    rm -f "${BACKUP_DIR}/converted"
    say "PostgreSQL-backed Vault started; unseal it as before"
    ;;

  retire)
    require_confirm "${1:-}" REMOVE-LEGACY-VAULT-PEER
    raft_mode || die "only a Raft node that was removed from the cluster can be retired"
    systemctl disable --now vault
    say "Vault stopped and disabled; its data directory is kept until decommissioning"
    ;;

  *)
    die "usage: $0 plan|apply|rollback|retire ..."
    ;;
esac
