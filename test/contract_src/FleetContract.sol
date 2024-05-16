// SPDX-License-Identifier: DIODE
// Diode Contracts
// Copyright 2021-2024 Diode
// Licensed under the Diode License, Version 1.0
pragma solidity >=0.7.6;
import "./IFleetContract.sol";

/**
 * FleetContract
 */
contract FleetContract is IFleetContract {
  address private _reserved_0;
  address public operator;
  address public accountant;
  uint256 private _reserved_1;
  bytes32 private _reserved_2;
  bytes32 private _reserved_3;
  mapping(address => bool) private allowlist;
  mapping(address => mapping(address => bool)) private _reserved_4;

  modifier onlyOperator {
    require(msg.sender == operator, "Only the operator can call this method");
    _;
  }

  modifier onlyAccountant {
    require(msg.sender == accountant, "Only the accountant can call this method");
    _;
  }

  constructor (address _operator, address _accountant) payable {
    operator = _operator;
    accountant = _accountant;
  }

  function Accountant() external override view returns (address) {
    return accountant;
  }

  function Operator() external view returns (address) {
    return operator;
  }

  function SetDeviceAllowlist(address _client, bool _value) public virtual onlyOperator {
    allowlist[_client] = _value;
  }

  function DeviceAllowlist(address _client) public view virtual override returns (bool) {
    return allowlist[_client];
  }


  /**************************************
   **   DEPRECATED FUNCTION ALIASES    **
   *************************************/
  function SetDeviceWhitelist(address _client, bool _value) external {
    SetDeviceAllowlist(_client, _value);
  }

  function deviceWhitelist(address _client) override external view returns (bool) {
    return DeviceAllowlist(_client);
  }
}
