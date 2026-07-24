#!/bin/bash

cd "$(dirname "$0")"

for name in $(cat names.txt); do
  echo "Syncing $name..."
  ./sync.exs "$name"
  sleep 10
done
