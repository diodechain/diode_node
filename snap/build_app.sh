#!/bin/bash
set -e
export MIX_ENV=prod
export ASDF_DIR=${HOME}/.asdf
. ${ASDF_DIR}/asdf.sh
mix deps.get
mix do clean, release --overwrite
