// SPDX-License-Identifier: DIODE
// Diode Contracts
// Copyright 2021-2024 Diode
// Licensed under the Diode License, Version 1.0
pragma solidity >=0.7.6;

library Utils {
  // spilit signature
  function splitSignature(bytes memory sig) internal pure returns (uint8 v, bytes32 r, bytes32 s) {
    require(sig.length == 65, "Wrong signature length");

    assembly {
      r := mload(add(sig, 32))
      s := mload(add(sig, 64))
      v := byte(0, mload(add(sig, 96)))
    }

    return (v, r, s);
  }

  // bytesToAddress
  function bytesToAddress(bytes memory _addressBytes) internal pure returns (address) {
    address _address;
    assembly {
      _address := mload(add(_addressBytes, 32))
    }
    return _address;
  }

  // bytes32ToAddress
  function bytes32ToAddress(bytes32 _addressBytes) internal pure returns (address) {
    uint256 _address;
    assembly {
      _address := add(_addressBytes, 0)
    }
    return address(uint160(_address));
  }

  // addressToBytes32
  function addressToBytes32(address _address) internal pure returns (bytes32) {
    bytes32 _bytes;
    assembly {
      _bytes := add(_address, 0)
    }
    return _bytes;
  }

  // bytes32Hash
  function bytes32Hash(bytes32[] memory _src) internal pure returns (bytes32) {
    return keccak256(abi.encodePacked(_src));
  }
}