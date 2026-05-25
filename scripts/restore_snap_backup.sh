#!/bin/bash
# Restore a diode-node backup created by the snap remove hook.
set -euo pipefail

usage() {
	cat <<EOF
Usage: $0 <backup.tar.gz>

Restores node identity and wallet data from an automatic snap-removal backup.
Run after reinstalling diode-node and stopping the service:

  sudo snap install diode-node
  sudo snap stop diode-node.service
  sudo $0 /var/backups/diode-node/diode_node_backup_YYYY-MM-DD_HHMMSS.tar.gz
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
	echo "Run this script inside the diode-node snap environment (e.g. sudo diode-node.shell)." >&2
	echo "Or set SNAP, SNAP_DATA, and SNAP_USER_DATA manually." >&2
	exit 1
fi

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
