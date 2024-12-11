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
    curl g++ make unzip procps libc6 libstdc++6 locales

# Installing libncurses for terminfo but ensuring
# it's statically linked:
RUN apt-get install -y libncurses-dev
RUN dpkg -L libncurses5-dev | grep ".so" | xargs rm
RUN dpkg -L libtinfo-dev | grep ".so" | xargs rm

ENV MIX_ENV=prod

COPY scripts/install_openssl.sh /app/
RUN /app/install_openssl.sh
COPY .tool-versions /root/

WORKDIR /app/
COPY . /app/
ENV HEX_HTTP_TIMEOUT=120
RUN /app/snap/build_prereq.sh
RUN /app/snap/build_app.sh
RUN mv /app/_build/prod/diode_node*.tar.gz /app/_build/prod/diode_node.tar.gz
