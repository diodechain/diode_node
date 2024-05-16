#!/bin/bash

while ! elixir bns.exs
do
  echo "Waiting 60 seconds"
  sleep 60
  echo "Restarting..."
done
