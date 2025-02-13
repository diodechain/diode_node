#!/bin/bash
set -e

if [ -z "$1" ]; then
    echo "Usage: $0 <epoch>"
    echo "Eg.  : $0 668"
    exit 1
fi

epoch=$1

elixir network.exs $epoch
elixir network_log_merge.exs $epoch > epoch_$epoch/network_log_merge.log
git add epoch_$epoch/
git diff epoch_$epoch/network_log_merge.log

