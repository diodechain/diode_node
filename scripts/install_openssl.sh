#!/bin/bash
export VSN=1.1.1w
export VSN_HASH=cf3098950cb4d853ad95c0841f1f9c6d3dc102dccfcacd521d93925208b76ac8

if [ -z "$OPENSSL_PREFIX" ]; then
export PREFIX=/usr/local/openssl
else
export PREFIX=$OPENSSL_PREFIX
fi 

# install openssl
echo "Build and install openssl......"
mkdir -p $PREFIX/ssl && \
    mkdir -p _build && \
    cd _build && \
    wget -nc https://www.openssl.org/source/openssl-$VSN.tar.gz && \
    [ "$VSN_HASH" = "$(sha256sum openssl-$VSN.tar.gz | cut -d ' ' -f1)" ] && \
    tar xzf openssl-$VSN.tar.gz && \
    cd openssl-$VSN && \
    ./config --prefix=$PREFIX "$@" && \
    make clean && make depend && make && make install_sw install_ssldirs

