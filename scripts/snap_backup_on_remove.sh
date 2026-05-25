#!/bin/bash
# Automatic wallet backup when the diode-node snap is removed.
# Invoked from snap/hooks/remove; BACKUP_DIR can be overridden for tests.
set -euo pipefail

BACKUP_DIR="${BACKUP_DIR:-/var/backups/diode-node}"
SNAP_NAME="${SNAP_NAME:-diode-node}"
staging_dir=""

log() {
	echo "diode-node remove hook: $*" >&2
}

stage_critical_files() {
	local snap_data="$1"
	local snap_user_data="$2"
	local staging_dir="$3"
	local has_data=0

	if [[ -f "$snap_user_data/node" ]]; then
		mkdir -p "$staging_dir/snap_user_data"
		cp "$snap_user_data/node" "$staging_dir/snap_user_data/"
		has_data=1
	fi

	if [[ -f "$snap_user_data/erl_inetrc" ]]; then
		mkdir -p "$staging_dir/snap_user_data"
		cp "$snap_user_data/erl_inetrc" "$staging_dir/snap_user_data/"
		has_data=1
	fi

	if [[ -d "$snap_data" ]]; then
		for nodedata in "$snap_data"/nodedata_*; do
			if [[ -d "$nodedata" ]]; then
				mkdir -p "$staging_dir/snap_data"
				cp -a "$nodedata" "$staging_dir/snap_data/"
				has_data=1
			fi
		done
	fi

	echo "$has_data"
}

write_manifest() {
	local staging_dir="$1"
	local snap_data="$2"
	local snap_user_data="$3"

	cat >"$staging_dir/manifest.txt" <<EOF
diode-node automatic backup
created: $(date -u +%Y-%m-%dT%H:%M:%SZ)
snap: ${SNAP_NAME}
snap_data: ${snap_data}
snap_user_data: ${snap_user_data}

Restore with bin/restore_snap_backup after reinstalling the snap
(connect backup-dir: sudo snap connect diode-node:backup-dir).
If this backup is missing, use "snap saved" within 31 days of removal.
EOF
}

main() {
	umask 077
	local snap_data="${SNAP_DATA:-}"
	local snap_user_data="${SNAP_USER_DATA:-}"

	if [[ -z "$snap_data" || -z "$snap_user_data" ]]; then
		log "SNAP_DATA or SNAP_USER_DATA not set, skipping backup"
		exit 0
	fi

	staging_dir=$(mktemp -d)
	trap '[[ -n "$staging_dir" ]] && rm -rf "$staging_dir"' EXIT

	local has_data
	has_data=$(stage_critical_files "$snap_data" "$snap_user_data" "$staging_dir")

	if [[ "$has_data" -eq 0 ]]; then
		log "no critical node data found, skipping backup"
		exit 0
	fi

	write_manifest "$staging_dir" "$snap_data" "$snap_user_data"

	if ! mkdir -p "$BACKUP_DIR" 2>/dev/null; then
		log "cannot create backup directory $BACKUP_DIR (is backup-dir plug connected?)"
		log "use 'snap saved' within 31 days to recover data via 'snap restore'"
		exit 0
	fi
	chmod 0700 "$BACKUP_DIR" 2>/dev/null || true

	local timestamp backup_file
	timestamp=$(date -u +%Y-%m-%d_%H%M%S)
	backup_file="$BACKUP_DIR/diode_node_backup_${timestamp}.tar.gz"

	if ! tar -czf "$backup_file" -C "$staging_dir" .; then
		log "failed to write backup archive to $backup_file"
		exit 0
	fi

	chmod 0600 "$backup_file"

	log "wallet backup saved to $backup_file"
}

main "$@"
