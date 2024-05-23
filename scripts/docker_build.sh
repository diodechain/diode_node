#!/bin/bash
# Diode Server
# Copyright 2021-2024 Diode
# Licensed under the Diode License, Version 1.1
set -e
export DOCKER_BUILDKIT=0
docker build . -t diode_node -f scripts/Dockerfile
CID=`docker create diode_node`
mkdir -p _build/prod
docker cp "$CID:/app/_build/prod/diode_node.tar.gz" _build/prod/
docker rm "$CID"
