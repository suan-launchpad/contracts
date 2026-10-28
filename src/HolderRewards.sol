// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IAgentId, IAgentToken} from "./interfaces/IAgentLaunch.sol";

interface IBalanceOf {
    function balanceOf(address account) external view returns (uint256);
}

/// @title HolderRewards
/// @notice BNB holder rewards with the "accumulated reward per share" pattern (same idea as four's TaxToken and
///         Flap's Dividend contract). A share is the token balance of an eligible address; deposits raise
///         `accPerShare`, nobody is looped over. Optionally only .ai wallets earn shares.
contract HolderRewards {
    uint256 private constant ACC = 1e36;
    /// @notice Gas forwarded when pushing BNB to a holder, so a reverting receiver cannot block a batch.
    uint256 private constant PUSH_GAS = 30_000;

    address public immutable token;
    IAgentId public immutable agentId;
    uint256 public immutable minShare;
    bool public immutable agentOnly;

    uint256 public accPerShare;
    uint256 public totalShares;
    /// @notice BNB received while no address held a share; added to the next distribution.
    uint256 public undistributed;

    mapping(address => uint256) public shareOf;
    mapping(address => uint256) private debt;
    mapping(address => uint256) private owed;

    event Deposited(uint256 amount, uint256 accPerShare);
    event Claimed(address indexed account, uint256 amount);

    error OnlyToken();

    constructor(address token_, address agentId_, uint256 minShare_, bool agentOnly_) {
        token = token_;
        agentId = IAgentId(agentId_);
        minShare = minShare_;
        agentOnly = agentOnly_;
    }

    /// @notice Called by the token after every balance change.
    function setShare(address account, uint256 balance) external {
        if (msg.sender != token) revert OnlyToken();
        _setShare(account, balance);
    }

    /// @notice Refresh an address's share, e.g. after it claimed a .ai Agent ID.
    function sync(address account) external {
        _setShare(account, IBalanceOf(token).balanceOf(account));
    }

    function deposit() external payable {
        uint256 amount = msg.value + undistributed;
        if (totalShares == 0) {
            undistributed = amount;
            return;
        }
        undistributed = 0;
        accPerShare += amount * ACC / totalShares;
        emit Deposited(amount, accPerShare);
    }

    function pending(address account) public view returns (uint256) {
        return owed[account] + shareOf[account] * accPerShare / ACC - debt[account];
    }

    function claim() external {
        _pay(msg.sender, type(uint256).max);
    }

    /// @notice Push rewards to many holders (keeper batch, like four's Keeper). Rewards go to each holder, never to the caller.
    function claimFor(address[] calldata accounts) external {
        for (uint256 i; i < accounts.length; ++i) {
            _pay(accounts[i], PUSH_GAS);
        }
    }

    function _eligibleShare(address account, uint256 balance) private view returns (uint256) {
        if (balance < minShare) return 0;
        if (IAgentToken(token).isRewardExcluded(account)) return 0;
        if (agentOnly && agentId.balanceOf(account) == 0) return 0;
        return balance;
    }

    function _setShare(address account, uint256 balance) private {
        uint256 next = _eligibleShare(account, balance);
        uint256 prev = shareOf[account];
        if (next == prev) return;
        owed[account] = pending(account);
        totalShares = totalShares - prev + next;
        shareOf[account] = next;
        debt[account] = next * accPerShare / ACC;
    }

    function _pay(address account, uint256 gasLimit) private {
        uint256 amount = pending(account);
        if (amount == 0) return;
        owed[account] = 0;
        debt[account] = shareOf[account] * accPerShare / ACC;
        (bool ok,) = account.call{value: amount, gas: gasLimit}("");
        if (!ok) {
            owed[account] = amount; // keep it claimable
            return;
        }
        emit Claimed(account, amount);
    }
}
