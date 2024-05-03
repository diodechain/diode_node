// SPDX-License-Identifier: DIODE
// Diode Contracts
// Copyright 2021-2024 Diode
// Licensed under the Diode License, Version 1.0
pragma solidity ^0.8.20;
pragma experimental ABIEncoderV2;

import "./BridgeIn.sol";
import "./BridgeOut.sol";

/**
 * Bridge contract
 */
contract Bridge is BridgeIn, BridgeOut {
    constructor(
        address _foundation,
        address[] memory _validators,
        uint256 _threshold
    )
        BridgeIn(block.chainid, _foundation, _validators, _threshold)
        BridgeOut(block.chainid, _foundation, address(diode))
    {
    }

    function initialize(address[] memory _validators, uint256 _threshold) public override initializer {
        BridgeIn.initialize(_validators, _threshold);
        BridgeOut.initialize();
    }

    function burnable() override public view returns (Burnable) {
        return Burnable(address(diode));
    }
}
