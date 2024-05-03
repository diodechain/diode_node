// SPDX-License-Identifier: DIODE
// Diode Contracts
// Copyright 2021-2024 Diode
// Licensed under the Diode License, Version 1.0
pragma solidity ^0.7.6;

/**
 * FleetContract
 */
interface FleetContractInterface {
  function Accountant() external view returns (address payable);
  function Operator() external view returns (address);
  function SetDeviceAllowlist(address _client, bool _value) external;
  function DeviceAllowlist(address _client) external view returns (bool);
}