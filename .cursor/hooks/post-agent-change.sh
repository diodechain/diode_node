#!/usr/bin/env bash
# Runs after each agent tool use (e.g. edits, writes).
# Formats and lints the Elixir codebase.
set -e
cd "$(git rev-parse --show-toplevel)"
mix format
mix lint
