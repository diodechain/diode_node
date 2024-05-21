// SPDX-License-Identifier: DIODE
// Diode Contracts
// Copyright 2021-2024 Diode
// Licensed under the Diode License, Version 1.0
pragma solidity >=0.7.6;
pragma experimental ABIEncoderV2;

contract ChangeTracker {
    bytes32 internal constant CHANGE_SLOT = 0x1e4717b2dc5dfd7f487f2043bfe9999372d693bf4d9c51b5b84f1377939cd487;

    function update_change_tracker() internal { 
        uint last_change = block.number;
        assembly {sstore(CHANGE_SLOT, last_change)} 
    } 

    function change_tracker() external view returns (uint) {
        uint last_change;
        assembly {last_change := sload(CHANGE_SLOT)}
        return last_change;
    }
}
