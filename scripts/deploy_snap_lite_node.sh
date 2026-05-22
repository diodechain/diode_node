#!/bin/bash
# Diode Server
# Copyright 2021-2024 Diode
# Licensed under the Diode License, Version 1.1
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REMOTE="${REMOTE:-lite-node}"

cd "$ROOT"
snapcraft

snap="$(find "$ROOT" -maxdepth 2 -name 'diode-node_*.snap' -type f -printf '%T@ %p\n' 2>/dev/null \
  | sort -rn | head -1 | cut -d' ' -f2-)"
if [ -z "${snap:-}" ]; then
  echo "error: no diode-node_*.snap found after snapcraft" >&2
  exit 1
fi

name="$(basename "$snap")"
echo "Deploying ${name} to ${REMOTE}..."
scp "${snap}" "${REMOTE}:"
ssh "${REMOTE}" "snap install --dangerous ~/${name}"
