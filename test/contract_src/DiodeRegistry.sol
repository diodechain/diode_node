// SPDX-License-Identifier: DIODE
// Diode Contracts
// Copyright 2021-2024 Diode
// Licensed under the Diode License, Version 1.0
pragma solidity ^0.7.6;
pragma experimental ABIEncoderV2;

import "./deps/Diode.sol";
import "./deps/Utils.sol";
import "./deps/SafeMath.sol";
import "./IFleetContract.sol";
import "./DiodeStake.sol";

/**
 * DiodeRegistry
 *
 * This registry implements
 *
 * 1. Registering Fleets & Devices
 *
 * 2. Submitting Service Tickets for Traffic and Connections
 *
 * 3. Per block evaluation
 * 3. 1. including distributing block rewards
 * 3. 2. including end of epoch distribution of service rewards
 *
 * NOTES:
 *    submitTicket is not secure because it depends on Fleetcontract.checkDevice
 *
 */

contract DiodeRegistry is DiodeStake {
  using SafeMath for uint256;

  uint256 currentEpoch = 0;
  uint8 constant BlockSeconds = 15;
  /*TEST_IF
  uint64 constant BlocksPerEpoch = 4;
  /*TEST_ELSE*/
  uint64 constant BlocksPerEpoch = 40320;
  /*TEST_END*/
  uint256 constant BlockReward = 1 ether;
  uint256 constant MinBlockRewards = 1000000000000000; // 1 finney
  uint256 constant Fractionals = 10000;
  uint256 constant MaxBlockSize = 20000000;
  uint256 constant UpperBlockSize = 10000000;
  uint256 constant LowerBlockSize =  5000000;
  address immutable Tester;
  address payable immutable Foundation;

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
   * FleetContracts => Miners(aka Nodes) => Devices(aka Client)
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
  address[] public rollupArray;
  mapping(address => uint256) rollupReward;

  // These two together form an iterable map for this Epochs activity
  IFleetContract[] fleetArray;
  mapping(address => FleetStats) fleetStats;
  function _fleetStats(IFleetContract _fleet) internal view returns (FleetStats storage) { return fleetStats[address(_fleet)]; }

  // This is the minimal fee above 0
  uint256 constant MinimumFee = 100;
  uint256 feePool;
  uint256 fee = 0;

  // ==================== DATA STRUCTURES ==================
  struct FleetStats {
    bool exists;

    uint256 totalConnections;
    uint256 totalBytes;

    // These two together form an iterable map
    address[] nodeArray;
    mapping(address => NodeStats) nodeStats;
  }

  struct NodeStats {
    bool exists;

    uint256 totalConnections;
    uint256 totalBytes;

    // These two together form an iterable map
    address[] clientArray;
    mapping(address => ClientStats) clientStats;
  }

  struct ClientStats {
    bool exists;
    uint256 clientIndex;

    uint256 totalConnections;
    uint256 totalBytes;
  }

  // ============= MODIFIERS ===============
  modifier onlyMiner() {
    /*TEST_IF
    /* 1. ganache bug https://github.com/trufflesuite/ganache-core/issues/201 */
    /* 2. during diode tests we run against coinbase independent contracts */
    if (msg.sender != block.coinbase && // normal rule
        block.coinbase != address(0) && // ganache exception
        msg.sender != Tester            // diode server exception
        )
    /*TEST_ELSE*/
    if (msg.sender != block.coinbase)
    /*TEST_END*/
      revert("Only the miner of the block can call this method");
    _;
  }

  modifier lastEpoch(uint256 blockHeight) {
    if (blockHeight >= block.number) revert("Ticket from the future?");
    /*TEST_IF
    /*TEST_ELSE*/
    if (blockHeight.div(BlocksPerEpoch) != currentEpoch - 1) revert("Wrong epoch");
    /*TEST_END*/
    _;
  }

  event Ticket(
    IFleetContract indexed fleetContract,
    address indexed node,
    address indexed client
  );

  event Rewards(
    address indexed node,
    uint256 indexed amount
  );

  constructor(address _tester, address payable _foundation) DiodeStake() {
    Tester = _tester;
    Foundation = _foundation;
  }

  // BlockTimeGoal is 15 seconds
  // One Epoch should be roughly one month
  function Epoch() public view returns (uint256) {
    return block.number.div(BlocksPerEpoch);
  }

  // MinTransactionFee() returns the current minimum gas price
  function MinTransactionFee() external view returns (uint256) {
    return fee;
  }

  // blockReward() -- needs to be called every block.
  function blockReward(uint256 _gasUsed, uint256 _weiSpent) external onlyMiner {
    _blockReward(_gasUsed, _weiSpent);
  }

  /**
   * blockReward() -- needs to be called every block.
   */
  function blockReward() external onlyMiner {
    _blockReward(0, 0);
  }

  /**
   * _blockReward() -- needs to be called every block.
   */
  function _blockReward(uint256 _gasUsed, uint256 _weiSpent) internal {
    // Calculcating per epoch service rewards
    if (currentEpoch != Epoch()) {
      endEpoch();
    }

    // Calculating block reward + earned fee
    {
      // First adding collected fee based.
      // We want to incentivize collecting large blocks.
      require(_weiSpent >= _gasUsed * fee, "Average gas price below current base fee");
      feePool += _weiSpent;

      // The reward is 10% of the current pool so miners receive 
      // a moving average. The first miner of a large transaction
      // receives the biggest chunk.
      uint256 reward = feePool / 10;
      
      // Deducting the reward from the pool
      feePool = feePool - reward;
      
      // In addition to the fees the miner is receiving the constant block reward
      reward += BlockReward;

      _minerRollup(block.coinbase, reward.mul(Fractionals));
      // Foundation is receiving 10% of the reward
      Foundation.transfer(reward.div(10));
    }

    // Fee adjustment calculation
    require(_gasUsed < MaxBlockSize, "Block is too big");
    if (_gasUsed >= UpperBlockSize) {
      fee += fee / 8;
      if (fee < MinimumFee) fee = MinimumFee;
    } else if (_gasUsed <= LowerBlockSize) {
      fee -= fee / 8;
      if (fee < MinimumFee) fee = 0;
    }

    // At this point all rewards and  service tickets should be accounted for and cleaned up.
    // rollupRewards should contain the final sum * Fractionals of reward for each miner.
    for (uint256 r = 0; r < rollupArray.length; r++) {
      address miner = rollupArray[r];
      uint256 reward = rollupReward[miner].div(Fractionals);

      uint256 maxReward = _miner(0, miner);
      if (maxReward < MinBlockRewards) {
        maxReward = MinBlockRewards;
      }
      if (reward > maxReward) {
        reward = maxReward;
      }
      if (reward > 0) {
        _minerStakeNow(miner, reward);
        emit Rewards(miner, reward);
      }
      delete rollupReward[miner];
    }
    delete rollupArray;
  }

  function endEpoch() private {
    address nodeAddress;
    uint256 reward;
    uint256 f;

    // This call is private and only done in the per block call
    // if (currentEpoch == Epoch()) revert("Can't end the current epoch");

    // Each fleet has a total value
    // We do have a fixed amount of revenue to distribute
    // Each fleets value should be distributed by share
    // We need to calculcate those shares first, by generating the total sum

    // ==ConnectionTickets (CTs)
    // CTs are calculcated as worth 1kb or traffic or 1024 totalBytes in
    // TrafficTickets (TTs)

    // ==Reward
    // Is either the sum of all active Fleet Contracts or the Value of all
    // each registered...
    // It's easier to just calculcate the value of each fleet contract
    // We distribute each round %1 percent of Fleet Contract Stake

    // Q: Is it better to copy fleetArray.length into a uint256 local var first?
    for (f = 0; f < fleetArray.length; f++) {
      IFleetContract fleetContract = fleetArray[f];

      uint256 fleetValue = _contractValue(fleetContract);
      reward = fleetValue.div(100);

      FleetStats storage fleet = _fleetStats(fleetContract);
      uint256 fleetPoints = fleet.totalBytes.add(fleet.totalConnections.mul(1024));

      for (uint256 n = 0; n < fleet.nodeArray.length; n++) {
        nodeAddress = fleet.nodeArray[n];
        NodeStats storage node = fleet.nodeStats[nodeAddress];

        uint256 nodePoints = node.totalBytes.add(node.totalConnections.mul(1024));
        // Out of all delivered fleetPoints the nodePoints are attributable to this node
        // next we're calculcating the corresponding reward from the reward pool of this fleet.
        // This nodes reward = nodePoints * (reward / fleetPoints)
        // This is multipled with 1000 to account for fractionals, needs to be divided
        // after summation.
        // uint256 nodeReward = nodePoints.mul(Fractionals).mul(reward).div(fleetPoints);
        nodePoints = nodePoints.mul(Fractionals).mul(reward).div(fleetPoints);

        // Summarizing in one reward per node to be applying capping and allow fractionals
        _minerRollup(nodeAddress, nodePoints);

        for (uint256 c = 0; c < node.clientArray.length; c++) {
          // Client Map Cleanup
          delete node.clientStats[node.clientArray[c]];
        }
        // Node Cleanup
        delete fleet.nodeStats[nodeAddress];
      }
      // Fleet Cleanup
      delete fleetStats[address(fleetContract)];
    }
    // Global cleanup
    delete fleetArray;

    // Update epoch
    currentEpoch = Epoch();
  }

  function _minerRollup(address miner, uint256 value) private {
    if (value > 0) {
      if (rollupReward[miner] == 0) {
        rollupArray.push(miner);
      }
      rollupReward[miner] = rollupReward[miner].add(value);
    }
  }

  /**
   * Submit one or more connection tickets raw
   *
   * Connection tickets
   *
   * [0] block height
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
    if (_connectionTicket.length == 0 || _connectionTicket.length % 9 != 0) revert("Invalid ticket length");

    for (uint256 i = 0; i < _connectionTicket.length; i += 9) {
      bytes32[3] memory deviceSignature = [_connectionTicket[i+6], _connectionTicket[i+7], _connectionTicket[i+8]];
      SubmitTicket(uint256(_connectionTicket[i+0]), IFleetContract(Utils.bytes32ToAddress(_connectionTicket[i+1])),
                             Utils.bytes32ToAddress(_connectionTicket[i+2]), uint256(_connectionTicket[i+3]),
                   uint256(_connectionTicket[i+4]), _connectionTicket[i+5], deviceSignature);
    }
  }

  function SubmitTicket(uint256 blockHeight, IFleetContract fleetContract, address nodeAddress,
                        uint256 totalConnections, uint256 totalBytes,
                        bytes32 localAddress, bytes32[3] memory signature) public lastEpoch(blockHeight) {
    require(totalConnections | totalBytes != 0, "Invalid ticket value");

    // ======= CLIENT SIGNATURE RECOVERY =======
    bytes32[] memory message = new bytes32[](6);
    message[0] = blockhash(blockHeight);
    message[1] = Utils.addressToBytes32(address(fleetContract));
    message[2] = Utils.addressToBytes32(nodeAddress);
    message[3] = bytes32(totalConnections);
    message[4] = bytes32(totalBytes);
    message[5] = localAddress;

    address client = ecrecover(Utils.bytes32Hash(message), uint8(uint256(signature[2])), signature[0], signature[1]);
    // ======= END =======

    validateFleetAccess(fleetContract, client);
    updateTrafficCount(fleetContract, nodeAddress, client, totalConnections, totalBytes);

    emit Ticket(fleetContract, nodeAddress, client);
  }


  // ====================================================================================
  // ============================= EXPLORATIVE ACCESSORS ================================
  // ====================================================================================

  // These types only exist for external accessors, hence avoid using mappings
  struct Fleet {
    IFleetContract fleet;
    uint256 totalConnections;
    uint256 totalBytes;
    address[] nodes;
  }

  struct Node {
    address node;
    uint256 totalConnections;
    uint256 totalBytes;
    Client[] clients;
  }

  struct Client {
    address client;
    uint256 totalConnections;
    uint256 totalBytes;
  }

  // These functions are only called by Web3 contract explorers
  function EpochFleets() external view returns (IFleetContract[] memory) {
    return fleetArray;
  }

  function EpochFleet(IFleetContract _fleet) external view returns (Fleet memory) {
    FleetStats storage stats = _fleetStats(_fleet);
    return Fleet(_fleet, stats.totalConnections, stats.totalBytes, stats.nodeArray);
  }

  function EpochFleetNode(IFleetContract _fleet, address _node) external view returns (Node memory) {
    FleetStats storage stats = _fleetStats(_fleet);
    NodeStats storage nstats = stats.nodeStats[_node];
    uint len = nstats.clientArray.length;
    Node memory node = Node(_node, nstats.totalConnections, nstats.totalBytes, new Client[](len));

    for (uint i = 0; i < len; i++) {
      address client = nstats.clientArray[i];
      ClientStats memory cstats = nstats.clientStats[client];
      node.clients[i] = Client(client, cstats.totalConnections, cstats.totalBytes);
    }

    return node;
  }

  function CurrentEpoch() external view returns (uint256) {
    return currentEpoch;
  }

  function FeePool() external view returns (uint256) {
    return feePool;
  }

  // ====================================================================================
  // ============================= INTERNAL FUNCTIONS ===================================
  // ====================================================================================
  function updateTrafficCount(IFleetContract fleetContract, address nodeAddress, address clientAddress,
                              uint256 totalConnections, uint256 totalBytes) internal {
    FleetStats storage fleet = _fleetStats(fleetContract);

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

    if (totalConnections > client.totalConnections) {
      uint256 newConnections = totalConnections - client.totalConnections;

      client.totalConnections = totalConnections;
      node.totalConnections = node.totalConnections.add(newConnections);
      fleet.totalConnections = fleet.totalConnections.add(newConnections);
    }

    if (totalBytes > client.totalBytes) {
      uint256 newBytes = totalBytes - client.totalBytes;

      client.totalBytes = totalBytes;
      node.totalBytes = node.totalBytes.add(newBytes);
      fleet.totalBytes = fleet.totalBytes.add(newBytes);
    }

    // Question should we revert() when there is no change ?
    //    Reverting might be cleaner but would also make batch submission of tickets
    //    more complicated.
  }

  function validateFleetAccess(IFleetContract fleetContract, address client) internal view {
    IFleetContract fc = IFleetContract(fleetContract);
    requiref(fc.deviceWhitelist(client), "Unregistered device", client);
  }

  /* TEST_IF
  function requiref(bool _test, string memory _format, address _arg) internal pure {
    if (!_test) {
      string memory output = string(abi.encodePacked(_format, " (", tohex(_arg), ")"));
      revert(output);
    }
  }
  bytes constant hexchars = "0123456789abcdef";
  function tohex(address _arg) internal pure returns (bytes memory) {
    bytes memory ret = new bytes(42);
    bytes20 b = bytes20(_arg);
    ret[0] = '0';
    ret[1] = 'x';
    for (uint i = 0; i < 20; i++) {
      ret[2*i+2] = hexchars[uint8(b[i]) / 16];
      ret[2*i+3] = hexchars[uint8(b[i]) % 16];
    }
    return ret;
  }
  /*TEST_ELSE*/
  function requiref(bool _test, string memory _format, address) internal pure {
    require(_test, _format);
  }
  /*TEST_END*/

}
