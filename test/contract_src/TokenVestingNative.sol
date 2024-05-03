// SPDX-License-Identifier: MIT
pragma solidity ^0.7.6;

import "./deps/Ownable.sol";
import "./deps/SafeMath.sol";

/**
 * @title TokenVesting
 * @dev A token holder contract that can release its token balance gradually like a
 * typical vesting scheme, with a cliff and vesting period. Optionally revocable by the
 * owner.
 */
contract TokenVestingNative is Ownable {
    // The vesting schedule is time-based (i.e. using block timestamps as opposed to e.g. block numbers), and is
    // therefore sensitive to timestamp manipulation (which is something miners can do, to a certain degree). Therefore,
    // it is recommended to avoid using short time durations (less than a minute). Typical vesting schemes, with a
    // cliff period of a year and a duration of four years, are safe to use.
    // solhint-disable not-rely-on-time

    using SafeMath for uint256;

    event TokensReleased(uint256 amount);
    event TokenVestingRevoked();

    // beneficiary of tokens after they are released
    address payable private _beneficiary;

    // Durations and timestamps are expressed in UNIX time, the same units as block.timestamp.
    uint256 private _cliff;
    uint256 private _start;
    uint256 private _duration;

    bool private _revocable;

    uint256 _released;
    bool _revoked;

    /**
     * @dev Creates a vesting contract that vests its balance of Eth to the
     * beneficiary, gradually in a linear fashion until start + duration. By then all
     * of the balance will have vested.
     * @param arg_beneficiary address of the beneficiary to whom vested tokens are transferred
     * @param cliffDuration duration in seconds of the cliff in which tokens will begin to vest
     * @param arg_start the time (as Unix time) at which point vesting starts
     * @param arg_duration duration in seconds of the period in which the tokens will vest
     * @param arg_revocable whether the vesting is revocable or not
     */
    constructor (address payable arg_beneficiary, uint256 arg_start, uint256 cliffDuration, uint256 arg_duration, bool arg_revocable) payable {
        require(arg_beneficiary != address(0), "TokenVesting: beneficiary is the zero address");
        // solhint-disable-next-line max-line-length
        require(cliffDuration <= arg_duration, "TokenVesting: cliff is longer than duration");
        require(arg_duration > 0, "TokenVesting: duration is 0");
        // solhint-disable-next-line max-line-length
        require(arg_start.add(arg_duration) > block.timestamp, "TokenVesting: final time is before current time");

        _beneficiary = arg_beneficiary;
        _revocable = arg_revocable;
        _duration = arg_duration;
        _cliff = arg_start.add(cliffDuration);
        _start = arg_start;
    }


    /**
     * Allowing later fund additions
     */
    receive() external payable { }

    /**
     * @return the beneficiary of the tokens.
     */
    function beneficiary() public view returns (address) {
        return _beneficiary;
    }

    /**
     * @return the cliff time of the token vesting.
     */
    function cliff() public view returns (uint256) {
        return _cliff;
    }

    /**
     * @return the start time of the token vesting.
     */
    function start() public view returns (uint256) {
        return _start;
    }

    /**
     * @return the duration of the token vesting.
     */
    function duration() public view returns (uint256) {
        return _duration;
    }

    /**
     * @return true if the vesting is revocable.
     */
    function revocable() public view returns (bool) {
        return _revocable;
    }

    /**
     * @return the amount of the token released.
     */
    function released() public view returns (uint256) {
        return _released;
    }

    /**
     * @return true if the token is revoked.
     */
    function revoked() public view returns (bool) {
        return _revoked;
    }

    /**
     * @notice Transfers vested tokens to beneficiary.
     */
    function release() public {
        uint256 unreleased = releasableAmount();

        require(unreleased > 0, "TokenVesting: no tokens are due");

        _released = _released.add(unreleased);

        _beneficiary.transfer(unreleased);

        emit TokensReleased(unreleased);
    }

    /**
     * @notice Allows the owner to revoke the vesting. Tokens already vested
     * remain in the contract, the rest are returned to the owner.
     */
    function revoke() public onlyOwner {
        require(_revocable, "TokenVesting: cannot revoke");
        require(!_revoked, "TokenVesting: token already revoked");

        uint256 balance = address(this).balance;

        uint256 unreleased = releasableAmount();
        uint256 refund = balance.sub(unreleased);

        _revoked = true;
        owner().transfer(refund);

        emit TokenVestingRevoked();
    }

    /**
     * @dev Calculates the amount that has already vested but hasn't been released yet.
     */
    function releasableAmount() public view returns (uint256) {
        return vestedAmount().sub(_released);
    }

    /**
     * @dev Calculates the amount that has already vested.
     */
    function vestedAmount() public view returns (uint256) {
        uint256 currentBalance = address(this).balance;
        uint256 totalBalance = currentBalance.add(_released);

        if (block.timestamp < _cliff) {
            return 0;
        } else if (block.timestamp >= _start.add(_duration) || _revoked) {
            return totalBalance;
        } else {
            return totalBalance.mul(block.timestamp.sub(_start)).div(_duration);
        }
    }
}
