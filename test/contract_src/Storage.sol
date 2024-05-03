// SPDX-License-Identifier: DIODE
// Diode Contracts
// Copyright 2021-2024 Diode
// Licensed under the Diode License, Version 1.0
pragma solidity ^0.7.6;
pragma experimental ABIEncoderV2;

/**
 * Generic Group
 */
contract Storage {
    function at(uint256 slot) public view returns (uint256 _value) {
        assembly { _value := sload(slot) }
    }

    function set_at(uint256 slot, uint256 value) internal {
        assembly { sstore(slot, value) }
    }

    function hash_at(uint256 base, uint256 key) public view returns (uint256) {
        return at(hash_slot(base, key));
    }

    function hash_set_at(uint256 base, uint256 key, uint256 value) public {
        set_at(hash_slot(base, key), value);
    }

    function hash_slot(uint256 base, uint256 key) internal pure returns (uint256) {
        return uint256(keccak256(abi.encodePacked(key, base)));
    }

    function list_size(uint256 base) public view returns (uint256) {
        return at(base);
    }

    function list_set_size(uint256 base, uint256 size) public {
        set_at(base, size);
    }

    function list_at(uint256 base, uint256 key) public view returns (uint256) {
        return at(list_slot(base, key));
    }

    function list_set_at(uint256 base, uint256 key, uint256 value) public {
        set_at(list_slot(base, key), value);
    }

    function list_push(uint256 base, uint256 value) public {
        uint256 size = list_size(base);
        list_set_at(base, size, value);
        list_set_size(base, size + 1);
    }

    function list_pop(uint256 base) public returns (uint256) {
        uint256 size = list_size(base) - 1;
        list_set_size(base, size);
        return list_at(base, size);
    }

    function list_slot(uint256 base, uint256 key) internal pure returns (uint256) {
        return uint256(keccak256(abi.encodePacked(base))) + key;
    }

}
