// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IAgentId, IAgentHookContext, PERMANENT} from "./interfaces/IAgentLaunch.sol";
import {StockHolderRewards} from "./StockHolderRewards.sol";
import {StockKnownPools} from "./libraries/StockKnownPools.sol";

/// @title StockToken
/// @notice Fixed-supply stock-meme token paired with a bStock in one hooked pool. Same transfer rules as AgentToken
///         (.ai window, 1% hold-cap window, tax period that refuses alternative pools and uncovered Vault transfers);
///         the differences are its holder rewards, paid in the bStock, and the extra alternative pools against the
///         bStock it refuses.
contract StockToken is ERC20 {
    uint256 public constant MAX_SUPPLY = 1_000_000_000 ether;
    /// @notice Per-address holding cap during the hold-cap window: 1% of the supply.
    uint256 public constant HOLD_CAP = MAX_SUPPLY / 100;
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;

    address public immutable hook;
    address public immutable creator;
    address public immutable vault;
    address public immutable altPoolManager;
    /// @notice The bStock this token trades against and pays its holder rewards in.
    address public immutable base;
    IAgentId public immutable agentId;
    StockHolderRewards public immutable rewards;
    uint64 public immutable launchTime;
    /// @notice Until then only .ai wallets may receive the token.
    uint64 public immutable aiOnlyUntil;
    /// @notice Until then no address may hold more than `HOLD_CAP`.
    uint64 public immutable holdCapUntil;
    /// @notice Until then the identity tax applies and alternative pools are refused; `PERMANENT` for never-ending.
    uint64 public immutable taxEnd;

    /// @notice IPFS CID of the token's image, description and links, set by the creator at launch.
    string public meta;

    mapping(address => bool) public isBlockedPool;

    error TransferLocked();
    error NotAgent(address account);
    error HoldCap(address account);
    error AltPoolBlocked(address pool);

    struct Config {
        string name;
        string symbol;
        string meta;
        address hook;
        address creator;
        address vault;
        address altPoolManager;
        address agentId;
        address base;
        uint64 aiOnlySeconds;
        uint64 holdCapSeconds;
        uint64 taxSeconds;
        uint256 minShare;
        bool agentOnlyRewards;
    }

    constructor(Config memory c) ERC20(c.name, c.symbol) {
        hook = c.hook;
        creator = c.creator;
        vault = c.vault;
        altPoolManager = c.altPoolManager;
        base = c.base;
        agentId = IAgentId(c.agentId);
        meta = c.meta;
        uint64 t = uint64(block.timestamp);
        launchTime = t;
        aiOnlyUntil = t + c.aiOnlySeconds;
        holdCapUntil = t + c.holdCapSeconds;
        taxEnd = c.taxSeconds == PERMANENT ? PERMANENT : t + c.taxSeconds;
        address[] memory pools = StockKnownPools.all(address(this), c.base);
        for (uint256 i; i < pools.length; ++i) {
            isBlockedPool[pools[i]] = true;
        }
        rewards = new StockHolderRewards(address(this), c.hook, c.vault, c.base, c.agentId, c.minShare, c.agentOnlyRewards);
        _mint(c.hook, MAX_SUPPLY);
    }

    function isAgent(address account) public view returns (bool) {
        return agentId.balanceOf(account) > 0;
    }

    /// @notice Addresses that never earn holder rewards.
    function isRewardExcluded(address account) public view returns (bool) {
        return account == address(0) || account == DEAD || account == address(this) || account == hook
            || account == vault || account == altPoolManager || account == address(rewards) || isBlockedPool[account];
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && from != hook && to != hook) {
            if (block.timestamp < aiOnlyUntil) _checkAiOnlyTransfer(from, to, value);
            else if (block.timestamp < taxEnd) _checkTaxPeriodTransfer(from, to, value);
            if (block.timestamp < holdCapUntil && to != vault && to != DEAD && balanceOf(to) + value > HOLD_CAP) {
                if (to != IAgentHookContext(hook).presaleRecipient(address(this))) revert HoldCap(to);
            }
        }
        super._update(from, to, value);
        // the only mint goes to the hook (never a shareholder) and runs inside the constructor
        if (from == address(0)) return;
        rewards.setShare(from, balanceOf(from));
        if (to != address(0)) rewards.setShare(to, balanceOf(to));
    }

    /// @dev .ai window: only Vault -> .ai wallet (buy delivery) and .ai wallet / creator -> Vault (sell), each covered
    ///      by a swap of this token's own pool in the same transaction.
    function _checkAiOnlyTransfer(address from, address to, uint256 value) private {
        IAgentHookContext ctx = IAgentHookContext(hook);
        if (from == vault) {
            if (!ctx.useVaultFlow(false, value)) revert TransferLocked();
            if (to != ctx.presaleRecipient(address(this)) && !isAgent(to)) revert NotAgent(to);
            return;
        }
        if (to == vault) {
            if (!ctx.useVaultFlow(true, value)) revert TransferLocked();
            if (from != creator && !isAgent(from)) revert NotAgent(from);
            return;
        }
        revert TransferLocked();
    }

    /// @dev Tax period: no known alternative pool, no Uniswap v4, and Vault transfers only as far as swaps in our own
    ///      pool cover them in this transaction.
    function _checkTaxPeriodTransfer(address from, address to, uint256 value) private {
        if (isBlockedPool[from]) revert AltPoolBlocked(from);
        if (isBlockedPool[to]) revert AltPoolBlocked(to);
        if (from == altPoolManager || to == altPoolManager) revert AltPoolBlocked(altPoolManager);
        IAgentHookContext ctx = IAgentHookContext(hook);
        if (from == vault && !ctx.useVaultFlow(false, value)) revert AltPoolBlocked(vault);
        if (to == vault && !ctx.useVaultFlow(true, value)) revert AltPoolBlocked(vault);
    }
}
