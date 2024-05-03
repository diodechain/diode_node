// SPDX-License-Identifier: DIODE
// Diode Contracts
// Copyright 2021-2024 Diode
// Licensed under the Diode License, Version 1.0
pragma solidity ^0.7.6;
import "./FleetContract.sol";

/**
 * DevFleetContract
 */
contract DevFleetContract is FleetContract {
  constructor (address payable _admin) FleetContract(_admin, _admin) {
  }

  function DeviceAllowlist(address) public pure override returns (bool) {
    return true;
  }
}