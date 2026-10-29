// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Currency} from "infinity-core/src/types/Currency.sol";
import {IVault} from "infinity-core/src/interfaces/IVault.sol";
import {ILockCallback} from "infinity-core/src/interfaces/ILockCallback.sol";
import {IAgentId, IAgentToken} from "./interfaces/IAgentLaunch.sol";

interface IStockBalanceOf {
    function balanceOf(address account) external view returns (uint256);
}

/// @title StockHolderRewards
/// @notice Holder rewards of a stock-meme token, paid in its bStock. Same "accumulated reward per share" accounting as
///         the BNB launchpad's HolderRewards. The hook mints each trade's holder share to this contract as PancakeSwap
///         Infinity Vault claims of the bStock in the trade itself, so no bStock transfer happens while trading and
///         nobody can time a payout. A claim turns claims back into bStock for the holder; a holder the bStock refuses
///         (blocked address, paused token) keeps its rewards owed and can claim again later.
contract StockHolderRewards is ILockCallback {
    uint256 private constant ACC = 1e36;

    address public immutable token;
    address public immutable hook;
    IVault public immutable vault;
    /// @notice The bStock the rewards are paid in.
    address public immutable asset;
    IAgentId public immutable agentId;
    uint256 public immutable minShare;
    bool public immutable agentOnly;

    uint256 public accPerShare;
    uint256 public totalShares;
    /// @notice bStock received while no address held a share; added to the next distribution.
    uint256 public undistributed;

    mapping(address => uint256) public shareOf;
    mapping(address => uint256) private debt;
    mapping(address => uint256) private owed;

    event Deposited(uint256 amount, uint256 accPerShare);
    event Claimed(address indexed account, uint256 amount);
    /// @notice The bStock refused the payout; the amount stays claimable.
    event ClaimFailed(address indexed account, uint256 amount);

    error OnlyToken();
    error OnlyHook();
    error OnlyVault();

    constructor(
        address token_,
        address hook_,
        address vault_,
        address asset_,
        address agentId_,
        uint256 minShare_,
        bool agentOnly_
    ) {
        token = token_;
        hook = hook_;
        vault = IVault(vault_);
        asset = asset_;
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
        _setShare(account, IStockBalanceOf(token).balanceOf(account));
    }

    /// @notice The hook minted `amount` of Vault claims of `asset` to this contract.
    function notifyReward(uint256 amount) external {
        if (msg.sender != hook) revert OnlyHook();
        amount += undistributed;
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
        _pay(msg.sender);
    }

    /// @notice Push rewards to many holders (keeper batch). Rewards go to each holder, never to the caller; a holder
    ///         the bStock refuses keeps its rewards and does not stop the batch.
    function claimFor(address[] calldata accounts) external {
        for (uint256 i; i < accounts.length; ++i) {
            _pay(accounts[i]);
        }
    }

    /// @dev Burns this contract's claims and sends the bStock to the holder, in one Vault lock.
    function lockAcquired(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(vault)) revert OnlyVault();
        (address account, uint256 amount) = abi.decode(data, (address, uint256));
        Currency c = Currency.wrap(asset);
        vault.burn(address(this), c, amount);
        vault.take(c, account, amount);
        return "";
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

    function _pay(address account) private {
        uint256 amount = pending(account);
        if (amount == 0) return;
        owed[account] = 0;
        debt[account] = shareOf[account] * accPerShare / ACC;
        try vault.lock(abi.encode(account, amount)) {
            emit Claimed(account, amount);
        } catch {
            owed[account] = amount; // keep it claimable
            emit ClaimFailed(account, amount);
        }
    }
}
