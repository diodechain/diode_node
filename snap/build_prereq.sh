#!/bin/bash
set -e
# Snap/LXD builds must not inherit git worktree env from the host (breaks asdf/erlang version fetch).
unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR || true
export CFLAGS="-O3"
export LDFLAGS="-static-libstdc++ -static-libgcc"
export KERL_CONFIGURE_OPTIONS="--disable-odbc --disable-javac --disable-debug --with-ssl=/usr/local/openssl/ --disable-dynamic-ssl-lib --without-cdv --without-wx"
export ASDF_DIR=${HOME}/.asdf

if [ ! -d /usr/local/openssl/ ]; then
    ./scripts/install_openssl.sh
fi

# Pin a pre–Go rewrite asdf release (current main is Go-only; no asdf.sh).
ASDF_GIT_TAG="${ASDF_GIT_TAG:-v0.14.0}"
if [ ! -f "${ASDF_DIR}/asdf.sh" ]; then
    rm -rf "${ASDF_DIR}"
    git clone --depth 1 --branch "${ASDF_GIT_TAG}" https://github.com/asdf-vm/asdf.git "${ASDF_DIR}"
fi

# shellcheck source=/dev/null
. "${ASDF_DIR}/asdf.sh"

if [ ! -d ${ASDF_DIR}/plugins/erlang ]; then
    asdf plugin add erlang
fi
asdf install erlang

if [ ! -d ${ASDF_DIR}/plugins/elixir ]; then
    asdf plugin add elixir
fi
asdf install elixir

export HEX_HTTP_TIMEOUT=120
mix local.hex --force --if-missing
mix local.rebar --force --if-missing
