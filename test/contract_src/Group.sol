// SPDX-License-Identifier: DIODE
// Diode Contracts
// Copyright 2021-2024 Diode
// Licensed under the Diode License, Version 1.0
pragma solidity ^0.7.6;
pragma experimental ABIEncoderV2;

import "./Storage.sol";
import "./Roles.sol";
import "./deps/OwnableInitializable.sol";
import "./deps/Set.sol";
import "./ChangeTracker.sol";

/**
 * Generic Group
 */
contract Group is Storage, OwnableInitializable, ChangeTracker {
    using Set for Set.Data;
    Set.Data members;
    uint256 constant DATA_SLOT = uint256(keccak256("DATA_SLOT"));

    modifier onlyMember virtual {
        require(owner() == msg.sender || members.IsMember(msg.sender), "Only members can call this");

        _;
    }

    constructor() {
        initialize(msg.sender);
        update_change_tracker();
    }

    function IsMember(address _member) external view returns (bool) {
        return _member == owner() || members.IsMember(_member);
    }

    function Members() external view virtual returns (address[] memory) {
        return members.Members();
    }

    function SetMemberValue(uint256 key, uint256 value) public {
        require(owner() == msg.sender || members.IsMember(msg.sender), "Only members can set member values");
        setDataValue(uint256(msg.sender), key, value);
    }

    function MemberValue(address member, uint256 key) public view returns (uint256) { 
        return dataValue(uint256(member), key);
    }

    function SetOwnerValue(uint256 key, uint256 value) public {
        require(owner() == msg.sender, "Only owners can set owner values");
        setDataValue(RoleType.Owner, key, value);
    }

    function OwnerValue(uint256 key) public view returns (uint256) { 
        return dataValue(RoleType.Owner, key);
    }

    function setDataValue(uint256 class, uint256 key, uint256 value) internal {
        hash_set_at(DATA_SLOT, uint256(keccak256(abi.encodePacked(class, key))), value);
        update_change_tracker();
    }

    function dataValue(uint256 class, uint256 key) internal view returns (uint256) {
        return hash_at(DATA_SLOT, uint256(keccak256(abi.encodePacked(class, key))));
    }

    function DataValue(uint256 class, uint256 key) external view returns (uint256) {
        return hash_at(DATA_SLOT, uint256(keccak256(abi.encodePacked(class, key))));
    }

    // call has been separated into its own function in order to take advantage
    // of the Solidity's code generator to produce a loop that copies tx.data into memory.
    function external_call(address destination, uint _dataLength, bytes memory _data) internal returns (bool) {
        bool result;
        assembly {
            let x := mload(0x40)   // "Allocate" memory for output (0x40 is where "free memory" pointer is stored by convention)
            let d := add(_data, 32) // First 32 bytes are the padded length of data, so exclude that
            result := call(
                sub(gas(), 34710),   // 34710 is the value that solidity is currently emitting
                                   // It includes callGas (700) + callVeryLow (3, to pay for SUB) + callValueTransferGas (9000) +
                                   // callNewAccountGas (25000, in case the destination address does not exist and needs creating)
                destination,
                0,                 // value is always zero
                d,
                _dataLength,        // Size of the input (in bytes) - this is what fixes the padding problem
                x,
                0                  // Output is ignored, therefore the output size is zero
            )
        }
        return result;
    }    
}
