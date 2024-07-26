#!/bin/bash
# Diode Server
# Copyright 2021-2024 Diode
# Licensed under the Diode License, Version 1.1
set -e
export ASDF_DIR=${HOME}/.asdf
. ${ASDF_DIR}/asdf.sh
exec mix eval --no-compile "IO.puts(Mix.Project.config()[:version])"
