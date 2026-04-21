#!/bin/bash
# Diode Server
# Copyright 2021-2024 Diode
# Licensed under the Diode License, Version 1.1
set -e
export DOCKER_BUILDKIT=0
export PLATFORM=${PLATFORM:-linux/amd64}

# Resolve the version description on the host (where git always works, even
# from a git worktree where .git is a pointer file). Pass it into the build
# as DIODE_VERSION_DESCRIPTION so mix.exs has the correct version even when
# the build context's .git would be unusable inside the container.
if DIODE_VERSION_DESCRIPTION=$(git describe --tags 2>/dev/null); then
    :
else
    DIODE_VERSION_DESCRIPTION="v0.0.0"
fi
export DIODE_VERSION_DESCRIPTION

docker build . \
    --platform=${PLATFORM} \
    --build-arg "DIODE_VERSION_DESCRIPTION=${DIODE_VERSION_DESCRIPTION}" \
    -t diode_node \
    -f scripts/Dockerfile
CID=$(docker create diode_node)
mkdir -p _build/prod
docker cp "$CID:/app/_build/prod/diode_node.tar.gz" _build/prod/
docker rm "$CID"
