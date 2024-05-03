// SPDX-License-Identifier: DIODE
// Diode Contracts
// Copyright 2021-2024 Diode
// Licensed under the Diode License, Version 1.0
pragma solidity ^0.7.6;
pragma experimental ABIEncoderV2;

import "./Group.sol";

/**
 * Generic Group
 */
contract RoleGroup is Group {
    using Set for Set.Data;
    mapping(address => uint256) roles; 

    modifier onlyAdmin {
        require(
            role(msg.sender) >= RoleType.Admin,
            "Only Admins and Owners can call this"
        );

        _;
    }

    function transferOwnership(address payable newOwner) public override onlyOwner {
        _add(owner(), RoleType.Admin);
        super.transferOwnership(newOwner);
        _add(owner(), RoleType.Owner);
    }

    function SetRoleValue(uint256 _role, uint256 _key, uint256 _value) public {
        require(role(msg.sender) >= _role, "Only higher roles can set this");
        setDataValue(_role, _key, _value);
    }

    function _add(address _member, uint256 _role) virtual internal {
        members.Add(_member);
        roles[_member] = _role;
    }

    function remove(address _member) virtual internal {
        members.Remove(_member);
        delete roles[_member];
    }

    function role(address _member) internal view returns (uint256) {
        if (_member == owner()) return RoleType.Owner;
        return roles[_member];
    }

    function Role(address _member) virtual external view returns (uint256) {
        return role(_member);
    }

    function AddMember(address _member) virtual external onlyAdmin {
        _add(_member, RoleType.Member);
    }

    function AddMember(address _member, uint256 _role) virtual external onlyOwner {
        _add(_member, _role);
    }

    function RemoveSelf() virtual external {
        remove(msg.sender);
    }

    function RemoveMember(address _member) virtual external onlyAdmin {
        remove(_member);
    }    
}
