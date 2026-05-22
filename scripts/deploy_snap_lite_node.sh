#!/bin/bash
# Diode Server
# Copyright 2021-2024 Diode
# Licensed under the Diode License, Version 1.1
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REMOTE="${REMOTE:-lite-node}"

snap_commit_postfix() {
  local name="$1"
  if [[ "$name" =~ -g([0-9a-f]+)_ ]]; then
    echo "${BASH_REMATCH[1]}"
  fi
}

fail_stale_snap() {
  local snap_commit="$1" head_commit="$2"
  echo -e "\033[0;31mWARNING: Snap commit postfix (${snap_commit}) does not match current git HEAD (${head_commit}).\033[0m" >&2
  echo "The snap was built from an older commit (snapcraft may have reused cached pull/build)." >&2
  echo "Run: snapcraft clean diode-node" >&2
  echo "Then rebuild and run this script again." >&2
  exit 1
}

cd "$ROOT"
snapcraft

snap="$(find "$ROOT" -maxdepth 2 -name 'diode-node_*.snap' -type f -printf '%T@ %p\n' 2>/dev/null \
  | sort -rn | head -1 | cut -d' ' -f2-)"
if [ -z "${snap:-}" ]; then
  echo "error: no diode-node_*.snap found after snapcraft" >&2
  exit 1
fi

name="$(basename "$snap")"
snap_commit="$(snap_commit_postfix "$name")"
if [ -n "${snap_commit:-}" ]; then
  head_commit="$(git rev-parse --short HEAD)"
  if ! git rev-parse --verify "${snap_commit}^{commit}" >/dev/null 2>&1 \
    || [ "$(git rev-parse "${snap_commit}^{commit}")" != "$(git rev-parse HEAD)" ]; then
    fail_stale_snap "$snap_commit" "$head_commit"
  fi
fi

echo "Deploying ${name} to ${REMOTE}..."
scp "${snap}" "${REMOTE}:"
ssh "${REMOTE}" "snap install --dangerous ~/${name}"
