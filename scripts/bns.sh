#!/bin/bash

cd "$(dirname "$0")"

while true
do
  elixir bns.exs 2>&1 >> bns.log
  echo "Waiting 60 seconds"
  sleep 60
  echo "Restarting..."
done
