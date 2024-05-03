// SPDX-License-Identifier: DIODE
// Diode Contracts
// Copyright 2021-2024 Diode
// Licensed under the Diode License, Version 1.0
pragma solidity ^0.7.6;
import "./FleetContract.sol";
import "./deps/Set.sol";

/**
 * ManagableFleetContract
 */
contract ManagableFleetContract is FleetContract {
  using Set for Set.Data;

  Set.Data members;

  constructor (address _operator, address _accountant) FleetContract(_operator, _accountant) {
  }

  function SetDeviceAllowlist(address _client, bool _value) public override onlyOperator {
    super.SetDeviceAllowlist(_client, _value);
    if (_value) {
      members.Add(_client);
    } else {
      members.Remove(_client);
    }
  }

  function DeviceList() external view returns (address[] memory) {
    return members.items;
  }

}