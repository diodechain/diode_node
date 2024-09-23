# Diode Server
# Copyright 2021-2024 Diode
# Licensed under the Diode License, Version 1.1
ARG BASE_IMAGE=ubuntu:18.04
FROM ${BASE_IMAGE}

# Installing deps
RUN apt-get update
RUN apt-get install -y \
    wget zlib1g-dev autoconf libtool \
    libgmp3-dev git \
    curl g++ make unzip procps libc6 libstdc++6

# Installing libncurses for terminfo but ensuring
# it's statically linked:
RUN apt-get install -y libncurses-dev
RUN dpkg -L libncurses5-dev | grep ".so" | xargs rm
RUN dpkg -L libtinfo-dev | grep ".so" | xargs rm

ENV MIX_ENV=prod

ARG OTP_VERSION
ENV OTP_VERSION=${OTP_VERSION:-OTP-26.2.5.3}
ARG OTP_GITHUB_URL
ENV OTP_GITHUB_URL=${OTP_GITHUB_URL:-https://github.com/erlang/otp.git}

ENV MAKEFLAGS="-j4"
ENV CFLAGS="-O3"
ENV ELIXIR_ERL_OPTIONS="+fnu"
ARG ELIXIR_VERSION
ENV ELIXIR_VERSION=${ELIXIR_VERSION:-1.15.8}
ARG ELIXIR_VARIANT
ENV ELIXIR_VARIANT=${ELIXIR_VARIANT:-"-otp-26"}

COPY scripts/install_openssl.sh /app/
RUN /app/install_openssl.sh

ENV ASDF_DIR=/root/.asdf
RUN git clone https://github.com/asdf-vm/asdf.git ${ASDF_DIR} && \
    . ${ASDF_DIR}/asdf.sh && \
    asdf plugin add elixir && \
    echo "elixir ${ELIXIR_VERSION}${ELIXIR_VARIANT}" >> .tool-versions && \
    asdf plugin add erlang && \
    echo "erlang ref:${OTP_VERSION}" >> .tool-versions

ENV KERL_CONFIGURE_OPTIONS="--disable-odbc --disable-javac --disable-debug --with-ssl=/usr/local/openssl/ --disable-dynamic-ssl-lib --without-cdv"
RUN . ${ASDF_DIR}/asdf.sh && asdf install

COPY mix.* /app/
COPY config/config.exs /app/config/
WORKDIR /app/
ENV HEX_HTTP_TIMEOUT=120
RUN . ${ASDF_DIR}/asdf.sh && \
    echo "elixir ${ELIXIR_VERSION}${ELIXIR_VARIANT}" > .tool-versions && \
    echo "erlang ref:${OTP_VERSION}" >> .tool-versions && \
    mix local.hex --force && mix local.rebar && mix deps.get && mix deps.compile

RUN . ${ASDF_DIR}/asdf.sh && \
    mix deps.compile libsecp256k1 && \
    cd deps/libsecp256k1 && \
    make 

COPY . /app/
RUN . ${ASDF_DIR}/asdf.sh && \
    echo "elixir ${ELIXIR_VERSION}${ELIXIR_VARIANT}" > .tool-versions && \
    echo "erlang ref:${OTP_VERSION}" >> .tool-versions && \
    mix compile && \
    mix release

RUN mv /app/_build/prod/diode_node*.tar.gz /app/_build/prod/diode_node.tar.gz
