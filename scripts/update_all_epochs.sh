#!/bin/bash
for epoch in $(seq 670 671); do
  ./update_epoch.sh $epoch
done
