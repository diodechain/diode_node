#!/bin/bash
apt install libssl-dev

asdf plugin add erlang
asdf plugin add elixir

export KERL_CONFIGURE_OPTIONS="--disable-odbc --disable-javac --disable-debug --without-termcap"

asdf install


mix deps.get
make -C deps/libsecp256k1
MIX_ENV=prod mix release
