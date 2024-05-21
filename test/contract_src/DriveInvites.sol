// SPDX-License-Identifier: DIODE
// Diode Contracts
// Copyright 2021-2024 Diode
// Licensed under the Diode License, Version 1.0
pragma solidity ^0.7.6;
pragma experimental ABIEncoderV2;

import "./deps/Set.sol";
import "./IDrive.sol";
import "./Roles.sol";
import "./ChangeTracker.sol";

/**
 * Drive Smart Contract
 * On-Chain invites for asynchronous eventing
 */

interface IDriveFactory {
    function Create2Address(bytes32 _salt) external view returns (IDrive);
}

contract DriveInvites is ChangeTracker {
    using Set for Set.Data;

    mapping(address => Set.Data) invites;
    address private immutable FACTORY;

    constructor(address _factory) {
        FACTORY = _factory;
        update_change_tracker();
    }

    function Version() external virtual pure returns (int256) {
        return 3;
    }

    // To be called by drive contract (msg.sender)
    function Invite(address driveId, address whom) public {
        require(driveId != address(0), "driveId can't be zero");
        require(factory() != IDriveFactory(0), "factory() can't be zero");
        // IDrive drive = factory().Create2Address(bytes32(uint256(driveId)));
        // require(drive != IDrive(0), "drive can't be zero");
        // require(drive.Role(msg.sender) >= RoleType.Admin, "Only Admins can invite");
        invites[whom].Add(driveId);
        update_change_tracker();
    }

    // To be called by drive contract (msg.sender)
    function Uninvite(address driveId, address whom) public {
        IDrive drive = factory().Create2Address(bytes32(uint256(driveId)));
        require(
            drive.Role(msg.sender) >= RoleType.Admin,
            "Only Admins can manage invites"
        );
        invites[whom].Remove(driveId);
        update_change_tracker();
    }

    // Called by the invitess to check (user)
    function Invites() public view returns (address[] memory) {
        return invites[msg.sender].Members();
    }

    // Called by the invitess to remove an invite after use (user)
    function PopInvite(address driveId) public {
        update_change_tracker();
        return invites[msg.sender].Remove(driveId);
    }

    // ######## ######## ######## ######## ######## ######## ######## ######## ########
    // ######## ######## ########   Internal only functions  ######## ######## ########
    // ######## ######## ######## ######## ######## ######## ######## ######## ########

    function factory() internal virtual view returns (IDriveFactory) {
        return IDriveFactory(FACTORY);
    }
}
