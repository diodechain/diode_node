// SPDX-License-Identifier: DIODE
// Diode Contracts
// Copyright 2021-2024 Diode
// Licensed under the Diode License, Version 1.0
pragma solidity >=0.7.6;

/**
 * IFleetContract
 */
interface IFleetContract {
    function Accountant() external view returns (address);
    function DeviceAllowlist(address _client) external view returns (bool);
    function deviceWhitelist(address _client) external view returns (bool);
}
