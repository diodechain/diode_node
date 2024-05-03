// SPDX-License-Identifier: DIODE
// Diode Contracts
// Copyright 2021-2024 Diode
// Licensed under the Diode License, Version 1.0
pragma solidity ^0.7.6;
pragma experimental ABIEncoderV2;

/**
 * BNS Blockchain Name System
 */
interface IBNS {
  struct BNSEntry {
      address   destination;
      address   owner;
      string    name;
      address[] destinations;
      string[]  properties;
      uint256   lockEnd;
      uint256   leaseEnd;
  }

  function Version() external pure returns (int);

  /**
   * Resolve `_name` and return one of the registered destinations.
   * @param _name the name to be resolved.
   */
  function Resolve(string calldata _name) external view returns (address);

  /**
   * Resolve `_name` and return one of the full BNSEntry.
   * @param _name the name to be resolved.
   */
  function ResolveEntry(string calldata _name) external view returns (BNSEntry memory);

  /**
   * Resolve `_name` and return the owner.
   * @param _name the name to be resolved.
   */
  function ResolveOwner(string calldata _name) external view returns (address);

  /**
   * Registers `_name` and assigns it to a single `_destination` address.
   * @param _name the name to be created.
   * @param _destination the single destination to be assigned.
   */
  function Register(string calldata _name, address _destination) external;

  /**
   * Transfers the ownership in `_name` to the new owner `_newowner`.
   * @param _name the name to be transferred.
   * @param _newowner the new owner to be assigned.
   */
  function TransferOwner(string calldata _name, address _newowner) external;

  /**
   * Renames the domain `_name` if and only if the new name `_newname` is free.
   * @param _name the name to be changed.
   * @param _newname the new name.
   */
  function Rename(string calldata _name, string calldata _newname) external;

  /**
   * Registers `_name` and assigns it to multiple `_destinations` addresses.
   * @param _name the name to be created.
   * @param _destinations array of destinations to be assigned.
   */
  function RegisterMultiple(string calldata _name, address[] calldata _destinations) external;

  /**
   * Unregister `_name` is a hashed name that is beeing deleted.
   * @param _name the name to be deleted.
   */
  function Unregister(string calldata _name) external;

  /**
   * AddProperty adds a new property to the domain.
   * @param _name the name of the domain.
   * @param _property the property string to be added.
   */
  function AddProperty(string calldata _name, string calldata _property) external;

  /**
   * DeleteProperty remove a property from the domain.
   * @param _name the name of the domain.
   * @param _idx the zero based index of the property to be deleted.
   */
  function DeleteProperty(string calldata _name, uint256 _idx) external;

  /**
   * GetProperty retrieves the indexed property of a domain.
   * @param _name the name of the domain.
   * @param _idx the zero based index of the property to be retrieved.
   */
  function GetProperty(string calldata _name, uint256 _idx) external view returns (string memory);

  /**
   * GetPropertyLength retrieves the number of properties for a domain.
   * @param _name the name of the domain.
   */
  function GetPropertyLength(string calldata _name) external view returns (uint256);

  /**
   * GetProperties retrieves all properties of a domain.
   * @param _name the name of the domain.
   */
  function GetProperties(string calldata _name) external view returns (string[] memory);

  /**
   * RegisterReverse sets at reverse lookup entry from `_address` to `_name`.
   * This requires an existing forward lookup from `_name` to `_address`.
   *
   * @param _name the name to be created.
   * @param _address the single destination to be assigned.
   */
  function RegisterReverse(address _address, string calldata _name) external;

  /**
   * UnregisterReverse deletes at reverse lookup entry for `_address`
   *
   * @param _address the single destination to be assigned.
   */
  function UnregisterReverse(address _address) external;

  /**
   * ResolveReverse resolves `_address` into a single name if a reverse lookup entry has
   * been created before using `RegisterReverse(address,string)`.
   * @param _address the name to be created.
   */
  function ResolveReverse(address _address) external view returns (string memory);
}
