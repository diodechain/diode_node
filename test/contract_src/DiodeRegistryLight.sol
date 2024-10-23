// SPDX-License-Identifier: DIODE
// Diode Contracts
// Copyright 2021-2024 Diode
// Licensed under the Diode License, Version 1.0
pragma solidity ^0.8.20;
pragma experimental ABIEncoderV2;

import "./deps/IERC20.sol";
import "./deps/SafeERC20.sol";
import "./deps/Utils.sol";
import "./deps/SafeMath.sol";
import "./deps/Initializable.sol";
import "./IFleetContract.sol";

/**
 * DiodeRegistry
 *
 * This registry implements
 *
 * 1. Registering Fleets
 * 2. Submitting Service Tickets for Traffic and Connections
 *
 */

contract DiodeRegistryLight is Initializable {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    uint64 public constant SecondsPerEpoch = 2_592_000;
    address public immutable Foundation;
    IERC20 public immutable Token;

    /**
     * Accounting Epochs run in two phases:
     *
     * EPOCH 0        | EPOCH 1       | EPOCH 2 ...
     * ============================================
     * 1. Collecting  |               |
     * 2. Submitting  | 1. Collecting |
     *    Payout      | 2. Submitting |  1. Collecting
     *                |    Payout     |  2. Submitting
     *                                |     Payout
     *
     * For accounting the activity from devices we maintain a three
     * level tree of iterable maps:
     *
     * FleetContracts => Relays => Devices(aka Client)
     *
     *   fleetStats[fleet].nodeStats[node].clientStats[client]
     *
     * Each device ticket is stored into this tree ensuring that
     * device activity is deduplicated on a per-node basis.
     *
     * Rollups of the total counts are done on the Nodes level as
     * well as on the Fleet level.
     *
     */
    address[] public relayArray;
    mapping(address => RelayReward) public relayRewards;

    struct RelayReward {
        bool exists;
        uint256 reward;
    }

    uint256 public currentEpoch;
    uint256 public currentEpochStart;
    uint256 public previousEpochStart;

    uint256 public foundationTaxRate;
    uint256 public foundationWithdrawableBalance;
    uint256 public connectionScore;
    uint256 public byteScore;

    // These two together form an iterable map for this Epochs activity
    IFleetContract[] public fleetArray;
    mapping(address => FleetStats) fleetStats;

    // ==================== DATA STRUCTURES ==================
    struct FleetStats {
        bool exists;
        uint256 currentBalance;
        uint256 withdrawRequestSize;
        uint256 withdrawableBalance;
        uint256 currentEpoch;
        uint256 score;
        // These two together form an iterable map
        address[] nodeArray;
        mapping(address => NodeStats) nodeStats;
    }

    struct NodeStats {
        bool exists;
        uint256 score;
        // These two together form an iterable map
        address[] clientArray;
        mapping(address => ClientStats) clientStats;
    }

    struct ClientStats {
        bool exists;
        uint256 score;
    }

    modifier onlyFoundation() {
        require(msg.sender == Foundation, "Foundation only");
        _;
    }

    constructor(address _foundation, IERC20 _token) {
        Foundation = _foundation;
        Token = _token;
        initialize();
    }

    function initialize() public initializer {
        foundationTaxRate = 1;
        connectionScore = 1024;
        byteScore = 1;
        currentEpoch = Epoch();
        currentEpochStart = block.number;
        previousEpochStart = block.number;
    }

    function ContractStake(IFleetContract _fleet, uint256 amount) public {
        require(
            _fleet.Accountant() == msg.sender,
            "Only the fleet accountant can do this"
        );

        FleetStats storage fleet = fleetStats[address(_fleet)];

        if (fleet.exists == false) {
            fleet.exists = true;
            fleetArray.push(_fleet);
        }

        Token.safeTransferFrom(msg.sender, address(this), amount);
        fleet.currentBalance += amount;
    }

    function ContractUnstake(IFleetContract _fleet, uint256 amount) public {
        require(
            _fleet.Accountant() == msg.sender,
            "Only the fleet accountant can do this"
        );
        FleetStats storage fleet = fleetStats[address(_fleet)];
        require(fleet.exists, "Only existing fleets can be unstaked");
        fleet.withdrawRequestSize = amount;
    }

    function ContractWithdraw(IFleetContract _fleet) public {
        require(
            _fleet.Accountant() == msg.sender,
            "Only the fleet accountant can do this"
        );
        FleetStats storage fleet = fleetStats[address(_fleet)];
        Token.safeTransfer(msg.sender, fleet.withdrawableBalance);
        fleet.withdrawableBalance = 0;
    }

    function FoundationWithdraw() public {
        Token.safeTransfer(Foundation, foundationWithdrawableBalance);
        foundationWithdrawableBalance = 0;
    }

    function RelayWithdraw(address nodeAddress) public {
        require (relayRewards[nodeAddress].reward > 0, "No rewards to withdraw");
        Token.safeTransfer(nodeAddress, relayRewards[nodeAddress].reward);
        relayRewards[nodeAddress].reward = 0;
    }

    function SetFoundationTax(uint256 _taxRate) external onlyFoundation {
        foundationTaxRate = _taxRate;
    }

    function SetByteScore(uint256 _byteScore) external onlyFoundation {
        byteScore = _byteScore;
    }

    function SetConnectionScore(
        uint256 _connectionScore
    ) external onlyFoundation {
        connectionScore = _connectionScore;
    }

    // One Epoch should be roughly one month
    function Epoch() public view returns (uint256) {
        return block.timestamp.div(SecondsPerEpoch);
    }

    function EndEpoch() public {
        require(currentEpoch != Epoch(), "Can't end the current epoch");
        doEndEpoch();
    }

    function doEndEpoch() internal {
        // Update epoch
        currentEpoch = Epoch();
        previousEpochStart = currentEpochStart;
        currentEpochStart = block.number;
    }

    function EndEpochForAllFleets() public {
        EndEpoch();
        for (uint f = 0; f < fleetArray.length; f++) {
            EndEpochForFleet(fleetArray[f]);
        }
    }

    function EndEpochForFleet(IFleetContract fleetContract) public {
        FleetStats storage fleet = fleetStats[address(fleetContract)];
        if (!fleet.exists) return;
        if (fleet.currentEpoch >= currentEpoch) return;
        fleet.currentEpoch = currentEpoch;

        uint256 reward = fleet.currentBalance / 100;
        // No traffic => no reward, and no tax
        if (fleet.score == 0) reward = 0;

        uint256 foundationTax = (reward * foundationTaxRate) / 100;

        // Still updating the withdrawable balance even if there is no reward
        fleet.currentBalance -= reward;
        if (fleet.currentBalance > fleet.withdrawRequestSize) {
            fleet.withdrawableBalance += fleet.withdrawRequestSize;
            fleet.currentBalance -= fleet.withdrawRequestSize;
        } else {
            fleet.withdrawableBalance += fleet.currentBalance;
            fleet.currentBalance = 0;
        }
        fleet.withdrawRequestSize = 0;

        // No need to continue beyond this point, if there is nothing to distribute
        reward -= foundationTax;
        if (reward == 0) return;
        uint rest = reward;

        for (uint256 n = 0; n < fleet.nodeArray.length; n++) {
            address nodeAddress = fleet.nodeArray[n];
            NodeStats storage node = fleet.nodeStats[nodeAddress];

            uint value = (reward * node.score) / fleet.score;

            if (value > 0) {
                if (!relayRewards[nodeAddress].exists) {
                    relayArray.push(nodeAddress);
                    relayRewards[nodeAddress].exists = true;
                }
                relayRewards[nodeAddress].reward += value;
                rest -= value;
            }

            for (uint256 c = 0; c < node.clientArray.length; c++) {
                // Client Map Cleanup
                delete node.clientStats[node.clientArray[c]];
            }
            // Node Cleanup
            delete fleet.nodeStats[nodeAddress];
        }

        foundationWithdrawableBalance += foundationTax + rest;
        // Fleet Cleanup
        fleet.score = 0;
        delete fleet.nodeArray;
    }

    /**
     * Submit one or more connection tickets raw
     *
     * Connection tickets
     *
     * [0] epoch
     * [1] fleet contract address
     * [2] node address
     * [3] total connections
     * [4] total bytes
     * [5] local address
     * [6] client sig r
     * [7] client sig s
     * [8] client sig v
     *
     * Requires an array with a length multiple of 9. Each 9 elements representing
     * a single connection ticket.
     */
    function SubmitTicketRaw(bytes32[] calldata _connectionTicket) external {
        if (_connectionTicket.length == 0 || _connectionTicket.length % 9 != 0)
            revert("Invalid ticket length");

        for (uint256 i = 0; i < _connectionTicket.length; i += 9) {
            bytes32[3] memory deviceSignature = [
                _connectionTicket[i + 6],
                _connectionTicket[i + 7],
                _connectionTicket[i + 8]
            ];
            SubmitTicket(
                uint256(_connectionTicket[i + 0]),
                IFleetContract(
                    Utils.bytes32ToAddress(_connectionTicket[i + 1])
                ),
                Utils.bytes32ToAddress(_connectionTicket[i + 2]),
                uint256(_connectionTicket[i + 3]),
                uint256(_connectionTicket[i + 4]),
                _connectionTicket[i + 5],
                deviceSignature
            );
        }
    }

    function SubmitTicket(
        uint256 epoch,
        IFleetContract fleetContract,
        address nodeAddress,
        uint256 totalConnections,
        uint256 totalBytes,
        bytes32 localAddress,
        bytes32[3] memory signature
    ) public {
        if (Epoch() != currentEpoch) {
            doEndEpoch();
        }
        EndEpochForFleet(fleetContract);
        require(epoch + 1 == currentEpoch, "Wrong epoch");
        require((totalConnections | totalBytes) != 0, "Invalid ticket value");

        // ======= CLIENT SIGNATURE RECOVERY =======
        bytes32[] memory message = new bytes32[](7);
        message[0] = bytes32(block.chainid);
        message[1] = bytes32(epoch);
        message[2] = Utils.addressToBytes32(address(fleetContract));
        message[3] = Utils.addressToBytes32(nodeAddress);
        message[4] = bytes32(totalConnections);
        message[5] = bytes32(totalBytes);
        message[6] = localAddress;

        address client = ecrecover(
            Utils.bytes32Hash(message),
            uint8(uint256(signature[2])),
            signature[0],
            signature[1]
        );
        // ======= END =======

        validateFleetAccess(fleetContract, client);
        updateTrafficCount(
            fleetContract,
            nodeAddress,
            client,
            totalConnections,
            totalBytes
        );
    }

    // ====================================================================================
    // ============================= EXPLORATIVE ACCESSORS ================================
    // ====================================================================================

    // These types only exist for external accessors, hence avoid using mappings
    struct FleetStat {
        bool exists;
        uint256 currentBalance;
        uint256 withdrawRequestSize;
        uint256 withdrawableBalance;
        uint256 currentEpoch;
        uint256 score;
    }

    struct Node {
        address node;
        uint256 score;
    }

    struct Client {
        address client;
        uint256 totalConnections;
        uint256 totalBytes;
    }

    // These functions are only called by Web3 contract explorers
    function FleetArray() external view returns (IFleetContract[] memory) {
        return fleetArray;
    }

    function FleetArrayLength() external view returns (uint) {
        return fleetArray.length;
    }

    function RelayArray() external view returns (address[] memory) {
        return relayArray;
    }

    function RelayArrayLength() external view returns (uint) {
        return relayArray.length;
    }

    function GetFleet(
        IFleetContract _fleet
    ) external view returns (FleetStat memory) {
        FleetStats storage f = fleetStats[address(_fleet)];
        return
            FleetStat(
                f.exists,
                f.currentBalance,
                f.withdrawRequestSize,
                f.withdrawableBalance,
                f.currentEpoch,
                f.score
            );
    }

    function GetClientScore(IFleetContract _fleet, address nodeAddress, address clientAddress) external view returns (uint256) {
        return fleetStats[address(_fleet)].nodeStats[nodeAddress].clientStats[clientAddress].score;
    }

    function GetNode(
        IFleetContract _fleet,
        address nodeAddress
    ) external view returns (Node memory) {
        NodeStats storage n = fleetStats[address(_fleet)].nodeStats[nodeAddress];
        Node memory node = Node(nodeAddress, n.score);
        return node;
    }

    function RelayRewards(address nodeAddress) external view returns (uint256) {
        return relayRewards[nodeAddress].reward;
    }

    // ====================================================================================
    // ============================= INTERNAL FUNCTIONS ===================================
    // ====================================================================================
    function updateTrafficCount(
        IFleetContract fleetContract,
        address nodeAddress,
        address clientAddress,
        uint256 totalConnections,
        uint256 totalBytes
    ) internal {
        FleetStats storage fleet = fleetStats[address(fleetContract)];
        uint256 score = totalConnections *
            connectionScore +
            totalBytes *
            byteScore;

        if (fleet.exists == false) {
            fleet.exists = true;
            fleetArray.push(fleetContract);
        }

        NodeStats storage node = fleet.nodeStats[nodeAddress];
        if (node.exists == false) {
            node.exists = true;
            fleet.nodeArray.push(nodeAddress);
        }

        ClientStats storage client = node.clientStats[clientAddress];
        if (client.exists == false) {
            client.exists = true;
            node.clientArray.push(clientAddress);
        }

        if (score > client.score) {
            uint256 delta = score - client.score;
            client.score += delta;
            fleet.score += delta;
            node.score += delta;
        }
    }

    function validateFleetAccess(IFleetContract fleetContract, address client) internal view {
        require(fleetContract.DeviceAllowlist(client), string(abi.encodePacked("Unregistered device\x00", address(client))));
    }

    function Version() external pure returns (uint256) {
        return 110;
    }
}
