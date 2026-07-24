#!/bin/bash

cd "$(dirname "$0")"

SEEDS=(us1 us2 eu1 eu2 as1 as2)

mapfile -t names < <(shuf names.txt)

for ((i = 0; i < ${#names[@]}; i += 6)); do
  pids=()
  for ((j = 0; j < 6 && i + j < ${#names[@]}; j++)); do
    name="${names[i + j]}"
    seed="${SEEDS[j]}.prenet.diode.io"
    echo "Syncing $name via $seed..."
    SEED_LIST="$seed" ./sync.exs "$name" &
    pids+=("$!")
  done

  for pid in "${pids[@]}"; do
    wait "$pid"
  done

  sleep 10
done
