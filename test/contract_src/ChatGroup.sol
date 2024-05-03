// SPDX-License-Identifier: DIODE
// Diode Contracts
// Copyright 2021-2024 Diode
// Licensed under the Diode License, Version 1.0
pragma solidity ^0.7.6;
pragma experimental ABIEncoderV2;

import "./RoleGroup.sol";

/**
 * Chat Smart Contract
 */
contract ChatGroup is RoleGroup {
    using Set for Set.Data;
    // List of group keys, only the most recent key should be
    // used for encryption
    uint256 constant GROUP_KEYS = uint256(keccak256("GROUP_KEYS"));
    uint256 constant ZONE = uint256(keccak256("ZONE"));

    function initialize(address payable owner, address _zone, address initial_key) public {
        set_at(ZONE, uint256(_zone));
        list_push(GROUP_KEYS, uint256(initial_key));
        super.initialize(owner);
    }

    function ElectNewOwner(address payable newOwner) external {
        require(zone().Role(msg.sender) >= RoleType.Admin, "Only zone admins can elect a new owner");
        require(!zone().IsMember(owner()), "Only deleted owners can be replaced");
        moveOwnership(newOwner);
    }

    function zone() internal view returns (ChatGroup) {
        return ChatGroup(address(at(ZONE)));
    }

    function AddKey(address key) external onlyAdmin {
        list_push(GROUP_KEYS, uint256(key));
    }

    function Key(uint256 index) external view returns (address) {
        return address(list_at(GROUP_KEYS, index));
    }
}
