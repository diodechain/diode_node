// SPDX-License-Identifier: DIODE
// Diode Contracts
// Copyright 2021-2024 Diode
// Licensed under the Diode License, Version 1.0
pragma solidity ^0.7.6;
pragma experimental ABIEncoderV2;

import "./deps/Set.sol";
import "./IDrive.sol";
import "./Roles.sol";

/**
 * Drive Smart Contract
 * On-Chain invites for asynchronous eventing
 */

interface IDriveFactory {
    function Create2Address(bytes32 _salt) external view returns (IDrive);
}

contract DriveInvites {
    using Set for Set.Data;

    mapping(address => Set.Data) invites;
    address private immutable FACTORY;

    constructor(address _factory) {
        FACTORY = _factory;
    }

    // To be called by drive contract (msg.sender)
    function Invite(address driveId, address whom) public {
        require(driveId != address(0), "driveId can't be zero");
        require(factory() != IDriveFactory(0), "factory() can't be zero");
        // IDrive drive = factory().Create2Address(bytes32(uint256(driveId)));
        // require(drive != IDrive(0), "drive can't be zero");
        // require(drive.Role(msg.sender) >= RoleType.Admin, "Only Admins can invite");
        invites[whom].Add(driveId);
    }

    // To be called by drive contract (msg.sender)
    function Uninvite(address driveId, address whom) public {
        IDrive drive = factory().Create2Address(bytes32(uint256(driveId)));
        require(
            drive.Role(msg.sender) >= RoleType.Admin,
            "Only Admins can manage invites"
        );
        invites[whom].Remove(driveId);
    }

    // Called by the invitess to check (user)
    function Invites() public view returns (address[] memory) {
        return invites[msg.sender].Members();
    }

    // Called by the invitess to remove an invite after use (user)
    function PopInvite(address driveId) public {
        return invites[msg.sender].Remove(driveId);
    }

    // ######## ######## ######## ######## ######## ######## ######## ######## ########
    // ######## ######## ########   Internal only functions  ######## ######## ########
    // ######## ######## ######## ######## ######## ######## ######## ######## ########

    function factory() internal virtual view returns (IDriveFactory) {
        return IDriveFactory(FACTORY);
    }
}
