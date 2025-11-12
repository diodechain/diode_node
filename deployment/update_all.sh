#!/bin/bash
set -e
echo "Copying new release to seeds"
fab install
for server in eu1 eu2 us1 us2 as1 as2; do
    echo "Updating seed $server"
    fab stop --host=root@$server.prenet.diode.io
    echo "Sleeping 5 minutes"
    sleep 300
done
