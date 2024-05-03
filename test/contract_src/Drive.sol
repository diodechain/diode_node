// SPDX-License-Identifier: DIODE
// Diode Contracts
// Copyright 2021-2024 Diode
// Licensed under the Diode License, Version 1.0
pragma solidity ^0.7.6;
pragma experimental ABIEncoderV2;

import "./IBNS.sol";
import "./IDrive.sol";
import "./RoleGroup.sol";
import "./Roles.sol";
import "./ChatGroup.sol";
import "./ManagedProxy.sol";
import "./IProxyResolver.sol";

/**
 * Drive Smart Contract
 */
contract Drive is IDrive, RoleGroup, IProxyResolver {
    using Set for Set.Data;
    address password_address;
    uint256 password_nonce;
    bytes   bns_name;
    uint256 bns_members;
    address private immutable BNS;
    address private immutable CHAT_IMPL = address(new ChatGroup());
    bytes32 constant CHAT_REF = keccak256("CHAT_REF");

    Set.Data chats;
    mapping(address => address) chat_contracts;

    struct JoinCode {
        address secret;
        uint256 nonce;
        uint256 expiry_time;
        uint256 expiry_count;
        uint256 target_role;
    }
    Set.Data join_code_set;
    mapping(address => JoinCode) join_code_data;

    constructor(address _bns) {
        BNS = _bns;
        initialize(msg.sender);
    }

    function Version() external virtual override pure returns (int256) {
        return 137;
    }

    function AddReader(address _member) external override onlyAdmin {
        _add(_member, RoleType.Reader);
    }

    function AddBackup(address _member) external override onlyAdmin {
        _add(_member, RoleType.BackupBot);
    }

    function Swap(address payable _multisig) external override {
        uint32 _size;
        address _sender = msg.sender;
        assembly { _size := extcodesize(_multisig) }
        require(_size > 0, "Can only swap for multisig smart contracts");
        assembly { _size := extcodesize(_sender) }
        require(_size == 0, "Can only swap from plain addresses");
        require(members.IsMember(msg.sender) || owner() == msg.sender, "Can only swap from members addresses");

        uint256 _role = role(msg.sender);
        if (owner() == msg.sender) {
            super.transferOwnership(_multisig);
            _role = RoleType.Owner;
        } else {
            uint256 _multirole = role(_multisig);
            if (_multirole > _role) _role = _multirole;
        }
        remove(msg.sender);
        _add(_multisig, _role);
    }

    function SetPasswordPublic(address _password) external override onlyOwner {
        password_address = _password;
        password_nonce = 0;
    }

    function Nonce() external override view returns (uint256) {
        return password_nonce;
    }

    function AddJoinCode(address _secret, uint256 _expiry_time, uint256 _expiry_count, uint256 _target_role) external {
        uint256 _role = role(msg.sender);
        require(_role >= RoleType.Admin, "Only Admins can call this");
        require(_target_role < _role, "Can only create invites to lower roles");
        require(join_code_set.IsMember(_secret) == false, "Join code already exists");
        join_code_set.Add(_secret);
        join_code_data[_secret] = JoinCode(_secret, 0, _expiry_time, _expiry_count, _target_role);
    }

    function UpdateJoinCode(address _secret, uint256 _expiry_time, uint256 _expiry_count, uint256 _target_role) external {
        uint256 _role = role(msg.sender);
        require(_role >= RoleType.Admin, "Only Admins can call this");
        require(_target_role < _role, "Can only update invites to lower roles");
        require(join_code_set.IsMember(_secret), "Join code does not exist");
        JoinCode storage jc = join_code_data[_secret];
        require(jc.target_role < _role, "Can only update invites with lower roles");
        jc.expiry_time = _expiry_time;
        jc.expiry_count = _expiry_count;
        jc.target_role = _target_role;
    }

    function Join(
        address _secret,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external {
        require(join_code_set.IsMember(_secret), "Join code does not exist");
        JoinCode storage jc = join_code_data[_secret];
        require(block.timestamp < jc.expiry_time, "Join code time expired");
        require(jc.expiry_count > 0, "Join code count expired");
        require(jc.target_role > 0, "Target role undefined");
        validate_join_code(jc.secret, jc.nonce, v, r, s);
        jc.nonce++;
        jc.expiry_count--;
        _add(msg.sender, jc.target_role);
    }

    function Join(
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external override {
        validate_join_code(password_address, password_nonce, v, r, s);
        password_nonce++;
        _add(msg.sender, RoleType.Member);
    }

    function Name() public override returns (string memory) {
        if (bns_name.length == 0) {
            bns_name = abi.encodePacked("drive-", encode(uint160(address(this))));
        }
        return string(bns_name);
    }

    function Migrate() public override {
        _add(owner(), RoleType.Owner);
    }

    function AddChat(address owner, address initial_key) external onlyMember {
        require(chat_contracts[initial_key] == address(0), "Chat already exists");
        ChatGroup chat = ChatGroup(address(new ManagedProxy(this, CHAT_REF)));
        chat.initialize(payable(owner), address(this), initial_key);
        chats.Add(address(chat));
        chat_contracts[initial_key] = address(chat);
    }

    function RemoveChat(address chat) external onlyMember {
        require(chats.IsMember(chat), "Chat does not exist");
        require(role(msg.sender) >= RoleType.Admin || ChatGroup(chat).Role(msg.sender) >= RoleType.Owner, "Only admins can remove chats");
        chats.Remove(chat);
        chat_contracts[ChatGroup(chat).Key(0)] = address(0);
    }

    function Chat(address initial_key) external view returns (address) {
        return chat_contracts[initial_key];
    }

    function Chats() external view virtual returns (address[] memory) {
        return chats.Members();
    }

    function resolve(bytes32 ref) external view override returns (address) {
        if (ref == CHAT_REF) {
            return address(CHAT_IMPL);
        }
        return address(0);
    }

    // ######## ######## ######## ######## ######## ######## ######## ######## ########
    // ######## ######## ########   Overrides       ######## ######## ######## ########
    // ######## ######## ######## ######## ######## ######## ######## ######## ########

    function AddMember(address _member) external override(RoleGroup, IDrive) onlyAdmin { 
        _add(_member, RoleType.Member);
    }

    function AddMember(address _member, uint256 _role) external override(IDrive, RoleGroup) onlyOwner {
        _add(_member, _role);
    }

    function RemoveSelf() external override(IDrive, RoleGroup) {
        remove(msg.sender);
    }

    function RemoveMember(address _member) external override(IDrive, RoleGroup) onlyAdmin {
        remove(_member);
    }

    function Members() external view override(IDrive, Group) returns (address[] memory) {
        return members.Members();
    }

    function Role(address _member) external view override(IDrive, RoleGroup) returns (uint256) {
        return role(_member);
    }

    // ######## ######## ######## ######## ######## ######## ######## ######## ########
    // ######## ######## ########   Internal only functions  ######## ######## ########
    // ######## ######## ######## ######## ######## ######## ######## ######## ########

    function bns() internal virtual view returns (IBNS) {
        return IBNS(BNS);
    }

    function register() internal {
        uint256 size = members.Size();
        if (size > 0 && size != bns_members && bns() != IBNS(0)) {
            bns().RegisterMultiple(Name(), members.Members());
            bns_members = size;
        }
    }

    function _add(address _member, uint256 _role) internal override {
        super._add(_member, _role);
        register();
    }

    function remove(address _member) internal override {
        super.remove(_member);
        register();
    }

    bytes constant chars = "0123456789abcdefghijklmnopqrstuvwxyz";
    function encode(uint160 _arg) internal pure returns (bytes memory) {
        bytes memory ret = new bytes(20);
        for (uint i = 0; i < 20; i++) {
            ret[i] = chars[_arg % 36];
            _arg = _arg / 36;
        }
        return ret;
    }

    function validate_join_code(
        address _password_address,
        uint256 _password_nonce,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) internal view {
        bytes memory prefix = "\x19Ethereum Signed Message:\n32";
        bytes32 prefixedHash = keccak256(
            abi.encodePacked(prefix, msg.sender, _password_nonce)
        );
        require(
            ecrecover(prefixedHash, v, r, s) == _password_address,
            "Invalid signature"
        );

    }
}
