#!/bin/bash
# Diode Server
# Copyright 2021-2024 Diode
# Licensed under the Diode License, Version 1.1
set -e

export MIX_ENV=prod
export CFLAGS="-O3"
export KERL_CONFIGURE_OPTIONS="--disable-odbc --disable-javac --disable-debug --with-ssl=/usr/local/openssl/ --disable-dynamic-ssl-lib --without-cdv"
export ELIXIR_ERL_OPTIONS="+fnu"
export ASDF_DIR=${HOME}/.asdf

if [ ! -d /usr/local/openssl/ ]; then
    ./scripts/install_openssl.sh
fi

if [ ! -d ${ASDF_DIR} ]; then
    git clone https://github.com/asdf-vm/asdf.git ${ASDF_DIR}
fi

. ${ASDF_DIR}/asdf.sh

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
mix deps.get
mix do clean, release --overwrite
