// SPDX-License-Identifier: DIODE
// Diode Contracts
// Copyright 2021-2024 Diode
// Licensed under the Diode License, Version 1.0
pragma solidity ^0.7.6;
pragma experimental ABIEncoderV2;

import "./deps/Set.sol";
import "./IBNS.sol";

/**
 * Drive Smart Contract
 */
contract Packages {
    struct Package {
        uint256 last_update;
        bytes32 package_hash; 
    }

    IBNS bns;
    mapping(bytes32 => Package) packages;

    modifier onlyDomainOwner(string memory _domain) {
        require(
            bns.ResolveEntry(_domain).owner == msg.sender,
            "Only the domain owner can call this"
        );

        _;
    }

    constructor(IBNS _bns) {
        bns = _bns;
    }

    function Version() external pure returns (int256) {
        return 100;
    }

    function AddPackage(string calldata _domain, string calldata _package_name, bytes32 _package_hash) external onlyDomainOwner(_domain) {
        packages[convert(_domain, _package_name)] = Package(block.number, _package_hash);
    }

    function DropPackage(string calldata _domain, string calldata _package_name) external onlyDomainOwner(_domain) {
        delete packages[convert(_domain, _package_name)];
    }

    function Lookup(string calldata _domain, string calldata _package_name) external view returns (Package memory) {
        return packages[convert(_domain, _package_name)];
    }

    function LookupHash(string calldata _domain, string calldata _package_name) external view returns (bytes32) {
        return packages[convert(_domain, _package_name)].package_hash;
    }

    function LookupLastUpdate(string calldata _domain, string calldata _package_name) external view returns (uint256) {
        return packages[convert(_domain, _package_name)].last_update;
    }

    function BNS() external view returns (IBNS) {
        return bns;
    }

    /*******************************************************
     ***********   INTERNAL FUNCTIONS **********************
     *******************************************************/    

    function convert(string memory _domain, string memory _package_name) internal pure returns (bytes32) {
        validate(_package_name);
        return keccak256(abi.encodePacked(_domain, "/", _package_name));
    }

    function validate(string memory name) internal pure {
        bytes memory b = bytes(name);

        require(b.length > 2, "Names must be longer than 2 characters");
        require(b.length <= 128, "Names must be within 128 characters");

        for(uint i; i < b.length; i++) {
            bytes1 char = b[i];

            require(
                (char >= 0x30 && char <= 0x39) || //9-0
                (char >= 0x41 && char <= 0x5A) || //A-Z
                (char >= 0x61 && char <= 0x7A) || //a-z
                (char == 0x2D) || (char == 0x2E) || (char == 0x5F), // -._
                "Names can only contain: [0-9A-Za-z_.-]");
        }
    }
}
