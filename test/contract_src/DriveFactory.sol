// SPDX-License-Identifier: DIODE
// Diode Contracts
// Copyright 2021-2024 Diode
// Licensed under the Diode License, Version 1.0
pragma solidity ^0.7.6;
pragma experimental ABIEncoderV2;

import "./Proxy.sol";

/**
 * Drive Smart Contract Factory
 * 
 * Used to instantiate
 *  - Drive.sol and
 *  - DriveMember.sol
 */
interface IInitializable {
    function initialize(address payable _owner) external;

    function owner() external view returns (address payable);
}

contract DriveFactory {
    function Create(
        address payable _owner,
        bytes32 _salt,
        address _target
    ) public returns (address) {
        address payable addr;
        // These are the first two arguments of Proxy(_target, _owner)
        bytes memory code = abi.encodePacked(
            type(Proxy).creationCode,
            abi.encode(address(0), address(this))
        );
        assembly {
            addr := create2(0, add(code, 0x20), mload(code), _salt)
            if iszero(extcodesize(addr)) {
                revert(0, 0)
            }
        }

        Proxy(addr)._proxy_set_target(_target);
        IInitializable(addr).initialize(_owner);
        return addr;
    }

    function Upgrade(bytes32 _salt, address _target) public {
        address addr = Create2Address(_salt);

        require(
            IInitializable(addr).owner() == msg.sender,
            "only the owner can upgrade"
        );
        Proxy(payable(addr))._proxy_set_target(_target);
    }

    function Create2Address(bytes32 _salt) public view returns (address) {
        bytes32 contractCodeHash = keccak256(
            abi.encodePacked(
                type(Proxy).creationCode,
                abi.encode(address(0), address(this))
            )
        );
        bytes32 rawAddress = keccak256(
            abi.encodePacked(
                bytes1(0xff),
                address(this),
                _salt,
                contractCodeHash
            )
        );

        return address(bytes20(rawAddress << 96));
    }
}
