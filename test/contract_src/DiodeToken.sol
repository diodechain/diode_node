// SPDX-License-Identifier: DIODE
// Diode Contracts
// Copyright 2021-2024 Diode
// Licensed under the Diode License, Version 1.0
pragma solidity ^0.8.20;
pragma experimental ABIEncoderV2;

import "./deps/Initializable.sol";
import "./deps/ERC20.sol";

/**
 * Diode Token
 */
contract DiodeToken is ERC20 {
    address public foundation;
    address public bridge;
    bool public transferable;
    mapping(address => bool) transferAllowlist;

    constructor(
        address _foundation,
        address _bridge,
        bool _transferable
    ) ERC20("Diode", "DIODE") {
        foundation = _foundation;
        bridge = _bridge;
        transferable = _transferable;

        if (foundation != address(0)) {
            transferAllowlist[foundation] = true;
        }
        if (bridge != address(0)) {
            transferAllowlist[bridge] = true;
        }
    }

    function initialize(
        address _foundation,
        address _bridge,
        bool _transferable
    ) public initializer {
        super.initialize("Diode", "DIODE");
        foundation = _foundation;
        bridge = _bridge;
        transferable = _transferable;

        if (foundation != address(0)) {
            transferAllowlist[foundation] = true;
        }
        if (bridge != address(0)) {
            transferAllowlist[bridge] = true;
        }
    }

    function mint(address to, uint256 amount) public {
        require(
            msg.sender == foundation || msg.sender == bridge,
            "DiodeToken: minting not allowed"
        );
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) public {
        require(
            msg.sender == foundation || msg.sender == bridge,
            "DiodeToken: burning not allowed"
        );
        _burn(from, amount);
    }

    function setTransferable(bool _transferable) public {
        require(
            msg.sender == foundation,
            "DiodeToken: only foundation can set transferable"
        );
        transferable = _transferable;
    }

    function setTransferAllowlist(address account, bool allow) public {
        require(
            msg.sender == foundation,
            "DiodeToken: only foundation can set transfer allowlist"
        );
        transferAllowlist[account] = allow;
    }

    function _update(
        address from,
        address to,
        uint256 value
    ) internal virtual override {
        require(
            transferable || transferAllowlist[from] || transferAllowlist[to],
            "DiodeToken: transfer not allowed"
        );
        return super._update(from, to, value);
    }
}
