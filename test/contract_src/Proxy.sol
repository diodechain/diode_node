// SPDX-License-Identifier: DIODE
// Diode Contracts
// Copyright 2021-2024 Diode
// Licensed under the Diode License, Version 1.0
pragma solidity >=0.7.6;

contract Proxy {
    bytes32 internal constant OWNER_SLOT = 0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;
    bytes32 internal constant TARGET_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    constructor(address _target, address _owner) {
        assembly {
            sstore(TARGET_SLOT, _target)
            sstore(OWNER_SLOT, _owner)
        } 
    } 

    function _proxy_set_owner(address _newowner) external {
        address owner;
        assembly {owner := sload(OWNER_SLOT)}
        if (owner == msg.sender) {
            assembly {sstore(OWNER_SLOT, _newowner)}
            return;
        }

        _fallback();
    }

    function _proxy_set_target(address _newtarget) external {
        address owner;
        assembly {owner := sload(OWNER_SLOT)}
        if (owner == msg.sender) {
            assembly {sstore(TARGET_SLOT, _newtarget)}
            return;
        }

        _fallback();
    }

    receive() external payable {
        _fallback();
    }

    fallback() external payable {
        _fallback();
    }

    function _fallback() internal {
        assembly {
            let target := sload(TARGET_SLOT)
            calldatacopy(0x0, 0x0, calldatasize())
            let result := delegatecall(gas(), target, 0, calldatasize(), 0x0, 0)
            returndatacopy(0x0, 0x0, returndatasize())
            switch result case 0 {revert(0, 0)} default {return (0, returndatasize())}
        }
    }
}
