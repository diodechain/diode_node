// SPDX-License-Identifier: DIODE
// Diode Contracts
// Copyright 2021-2024 Diode
// Licensed under the Diode License, Version 1.0
pragma solidity ^0.7.6;
pragma experimental ABIEncoderV2;

library RoleType {
    uint256 public constant None = 0;
    uint256 public constant BackupBot = 100;
    uint256 public constant Reader = 200;
    uint256 public constant Member = 300;
    uint256 public constant Admin = 400;
    uint256 public constant Owner = 500;
}
