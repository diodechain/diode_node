#!/bin/bash
# Diode Server
# Copyright 2021-2024 Diode
# Licensed under the Diode License, Version 1.1
if [[ $1 == "" ]]; then
  echo "Need host parameter"
  echo "You can try localhost:8545"
  exit
fi

host=$1

# Just some rpc examples using curl
# curl -X POST --data '{"jsonrpc":"2.0","method":"eth_getLogs","params":["0x16"],"id":73}' $host

echo "RemoteChain ID:"
curl -k -H "Content-Type: application/json" -X POST --data '{"jsonrpc":"2.0","method":"eth_chainId","id":73}' $host
echo ""

# Counts the number of fleet contracts
echo "Total Fleets:"
curl -k -H "Content-Type: application/json" -X POST --data '{"jsonrpc":"2.0","method":"dio_codeCount","params":["0x7e9d94e966d33cff302ef86e2337df8eaf9a6388d45e4744321240599d428343"],"id":73}' $host
echo ""

# Counts all accounts by hash
# 0xe3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855 is the null hash
echo "All Codes:"
curl -k -H "Content-Type: application/json"  -X POST --data '{"jsonrpc":"2.0","method":"dio_codeGroups","params":["0x16"],"id":73}' $host
echo ""

# Counts all balances
echo "Total Balances:"
curl -k -H "Content-Type: application/json"  -X POST --data '{"jsonrpc":"2.0","method":"dio_supply","params":["0x16"],"id":73}' $host
echo ""

# Counts traffic
echo "Traffic:"
curl -k -H "Content-Type: application/json"  -X POST --data '{"jsonrpc":"2.0","method":"dio_traffic","params":[15],"id":74}' $host
echo ""

echo "Usage:"
curl -k -H "Content-Type: application/json"  -X POST --data '{"jsonrpc":"2.0","method":"dio_usage","params":[],"id":74}' $host
echo ""

echo "Usage History:"
curl -k -H "Content-Type: application/json"  -X POST --data '{"jsonrpc":"2.0","method":"dio_usageHistory","params":[1719312049, 1719312149, 10],"id":74}' $host
echo ""

echo "Proxy Usage History:"
curl -k -H "Content-Type: application/json"  -X POST --data '{"jsonrpc":"2.0","method":"dio_proxy|dio_usage","params":["0xf188acf5e19f0ac06b4b60d77b477e0ef8c658f4"],"id":74}' $host
echo ""


