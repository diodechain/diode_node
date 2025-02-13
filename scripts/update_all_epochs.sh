#!/bin/bash
for epoch in $(seq 668 671); do
  ./update_epoch.sh $epoch
done
