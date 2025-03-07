#!/bin/bash
for epoch in $(seq 669 671); do
  ./update_epoch.sh $epoch
done
