// SPDX-License-Identifier: DIODE
// Diode Contracts
// Copyright 2021-2024 Diode
// Licensed under the Diode License, Version 1.0
pragma solidity ^0.7.6;
import "./deps/Ownable.sol";

contract ProxyResolver is Ownable {
    mapping(bytes32 => address) delegates;

    function update(bytes32 ref, address newDelegateAddress) public onlyOwner {
        delegates[ref] = newDelegateAddress;
    }

    function resolve(bytes32 ref) external view returns (address) {
        return delegates[ref];
    }
}