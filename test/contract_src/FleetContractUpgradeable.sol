// SPDX-License-Identifier: DIODE
// Diode Contracts
// Copyright 2021-2024 Diode
// Licensed under the Diode License, Version 1.0
pragma solidity ^0.7.6;
import "./DiodeRegistry.sol";
import "./IFleetContract.sol";

/**
 * FleetContract
 */
contract FleetContractUpgradeable is IFleetContract {
    DiodeRegistry private registry;
    address public operator;
    address payable public accountant;
    uint256 private _reserved_1;
    bytes32 private _reserved_2;
    bytes32 private _reserved_3;
    mapping(address => bool) private allowlist;
    mapping(address => mapping(address => bool)) private _reserved_4;
    address private immutable REGISTRY;

    /**
    * @dev Indicates that the contract has been initialized.
    */
    bool private initialized;

    /**
    * @dev Indicates that the contract is in the process of being initialized.
    */
    bool private initializing;

    /**
    * @dev Modifier to use in the initializer function of a contract.
    */
    modifier initializer() {
        require(initializing || isConstructor() || !initialized, "Contract instance has already been initialized");

        bool isTopLevelCall = !initializing;
        if (isTopLevelCall) {
            initializing = true;
            initialized = true;
        }

        _;

        if (isTopLevelCall) {
            initializing = false;
        }
    }

    /// @dev Returns true if and only if the function is running in the constructor
    function isConstructor() private view returns (bool) {
        // extcodesize checks the size of the code stored in an address, and
        // address returns the current address. Since the code is still not
        // deployed when running a constructor, any checks on its code size will
        // yield zero, making it an effective way to detect if a contract is
        // under construction or not.
        address self = address(this);
        uint256 cs;
        assembly { cs := extcodesize(self) }
        return cs == 0;
    }


    modifier onlyOperator() {
        require(
            msg.sender == operator,
            "Only the operator can call this method"
        );
        _;
    }

    modifier onlyAccountant() {
        require(
            msg.sender == accountant,
            "Only the accountant can call this method"
        );
        _;
    }

    constructor(address _registry) initializer {
        REGISTRY = _registry;
        initialized = true;
    }

    function initialize(address payable _owner) public initializer payable {
        registry = DiodeRegistry(REGISTRY);
        operator = _owner;
        accountant = _owner;
        if (msg.value > 0)
            registry.ContractStake{value: msg.value, gas: gasleft()}(this);
    }

    function Accountant() override external view returns (address) {
        return accountant;
    }

    function Operator() external view returns (address) {
        return operator;
    }

    function SetDeviceAllowlist(address _client, bool _value)
        public
        virtual
        onlyOperator
    {
        allowlist[_client] = _value;
    }

    function DeviceAllowlist(address _client)
        public
        view
        virtual
        returns (bool)
    {
        return allowlist[_client];
    }


  /*******************************
   **   DEPRECATED FUNCTIONS    **
   *******************************/
  function SetDeviceWhitelist(address _client, bool _value) external {
    SetDeviceAllowlist(_client, _value);
  }

  function deviceWhitelist(address _client) override external view returns (bool) {
    return DeviceAllowlist(_client);
  }
}
