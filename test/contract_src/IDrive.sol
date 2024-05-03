// SPDX-License-Identifier: DIODE
// Diode Contracts
// Copyright 2021-2024 Diode
// Licensed under the Diode License, Version 1.0
pragma solidity ^0.7.6;
pragma experimental ABIEncoderV2;

interface IDrive {
    function Version() external pure returns (int256);

    function AddMember(address _member) external;

    function AddReader(address _member) external;

    function AddBackup(address _member) external;

    function AddMember(address _member, uint256 role) external;

    function Swap(address payable _multisig) external;

    function RemoveSelf() external;

    function RemoveMember(address _member) external;

    function Members() external view returns (address[] memory);

    function Role(address _member) external view returns (uint256);

    function SetPasswordPublic(address _password) external;

    function Nonce() external view returns (uint256);

    function Join(
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external;

    function Name() external returns (string memory);

    function Migrate() external;
}
