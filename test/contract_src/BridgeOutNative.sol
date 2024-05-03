// SPDX-License-Identifier: DIODE
// Diode Contracts
// Copyright 2021-2024 Diode
// Licensed under the Diode License, Version 1.0
pragma solidity ^0.8.20;

import "./deps/Initializable.sol";

/**
 * BridgeOutNative contract
 */
contract BridgeOutNative is Initializable {
    struct Transaction {
        address sender;
        address destination;
        uint256 amount;
        uint256 timestamp;
        uint256 blockNumber;
        bytes32 historyHash;
    }

    struct Sig {
        uint8 v;
        bytes32 r;
        bytes32 s;
    }

    mapping(uint256 => Transaction[]) public txs;

    // This should always match block.chainid
    // but for testing it makes sense to override this
    uint256 public immutable chainid;
    mapping(uint256 => bool) public enabledChains;
    address immutable foundation;
    constructor(uint256 _chainid, address _foundation) {
        chainid = _chainid;
        foundation = _foundation;
        initialize();
    }

    function initialize() public initializer {
        enabledChains[1284] = true;
    }

    function setEnabledChain(uint256 chain, bool enabled) public {
        require(msg.sender == foundation, "BridgeOutNative: only foundation can set enabled chain");
        enabledChains[chain] = enabled;
    }

    function txsLength(uint256 chain) public view returns (uint256) {
        return txs[chain].length;
    }

    function txsAt(
        uint256 chain,
        uint256 index
    ) public view returns (Transaction memory) {
        return txs[chain][index];
    }

    function bridgeOut(
        address destination,
        uint256 destinationChain
    ) public payable {
        _bridgeOut(destination, destinationChain);
    }

    function bridgeOut(address destination) public payable {
        _bridgeOut(destination, 1284);
    }

    function bridgeOut() public payable {
        _bridgeOut(msg.sender, 1284);
    }

    function _bridgeOut(
        address destination,
        uint256 destinationChain
    ) internal {
        require(
            enabledChains[destinationChain],
            "BridgeOut: destination chain is not enabled"
        );
        require(
            msg.value >= 10000000000000000,
            "BridgeOut: value must be at least 0.01 $DIODE"
        );
        uint256 len = txs[destinationChain].length;
        bytes32 prev = len == 0
            ? keccak256(
                abi.encodePacked(
                    chainid,
                    "diode_bridge_genesis",
                    destinationChain
                )
            )
            : txs[destinationChain][len - 1].historyHash;
        bytes32 historyHash = keccak256(
            abi.encodePacked(destination, msg.value, prev)
        );
        txs[destinationChain].push(
            Transaction({
                sender: msg.sender,
                destination: destination,
                amount: msg.value,
                timestamp: block.timestamp,
                blockNumber: block.number,
                historyHash: historyHash
            })
        );
    }
}
