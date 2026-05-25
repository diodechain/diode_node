#!/bin/bash
# Restore a diode-node backup created by the snap remove hook.
set -euo pipefail

usage() {
	cat <<EOF
Usage: $0 <backup.tar.gz>

Restores node identity and wallet data from an automatic snap-removal backup.
Run after reinstalling diode-node and stopping the service:

  sudo snap install diode-node
  sudo snap connect diode-node:backup-dir
  sudo snap stop diode-node.service
  sudo snap run --shell diode-node -c 'bin/restore_snap_backup /var/backups/diode-node/diode_node_backup_YYYY-MM-DD_HHMMSS.tar.gz'
  sudo snap start diode-node.service
EOF
}

if [[ $# -ne 1 ]]; then
	usage
	exit 1
fi

backup_file="$1"

if [[ ! -f "$backup_file" ]]; then
	echo "Backup file not found: $backup_file" >&2
	exit 1
fi

if [[ -z "${SNAP:-}" || -z "${SNAP_DATA:-}" || -z "${SNAP_USER_DATA:-}" ]]; then
	echo "Run inside the diode-node snap (connect backup-dir first):" >&2
	echo "  sudo snap connect diode-node:backup-dir" >&2
	echo "  sudo snap run --shell diode-node -c 'bin/restore_snap_backup <backup.tar.gz>'" >&2
	exit 1
fi

umask 077
staging_dir=$(mktemp -d)
trap 'rm -rf "$staging_dir"' EXIT

tar -xzf "$backup_file" -C "$staging_dir"

if [[ -d "$staging_dir/snap_user_data" ]]; then
	mkdir -p "$SNAP_USER_DATA"
	cp -a "$staging_dir/snap_user_data/." "$SNAP_USER_DATA/"
fi

if [[ -d "$staging_dir/snap_data" ]]; then
	mkdir -p "$SNAP_DATA"
	cp -a "$staging_dir/snap_data/." "$SNAP_DATA/"
fi

echo "Restored backup into $SNAP_DATA and $SNAP_USER_DATA"
