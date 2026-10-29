// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "infinity-core/src/types/PoolId.sol";
import {Currency} from "infinity-core/src/types/Currency.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "infinity-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary, toBeforeSwapDelta} from "infinity-core/src/types/BeforeSwapDelta.sol";
import {IVault} from "infinity-core/src/interfaces/IVault.sol";
import {ILockCallback} from "infinity-core/src/interfaces/ILockCallback.sol";
import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {ICLHooks} from "infinity-core/src/pool-cl/interfaces/ICLHooks.sol";
import {
    HOOKS_BEFORE_INITIALIZE_OFFSET,
    HOOKS_BEFORE_ADD_LIQUIDITY_OFFSET,
    HOOKS_BEFORE_SWAP_OFFSET,
    HOOKS_AFTER_SWAP_OFFSET,
    HOOKS_BEFORE_DONATE_OFFSET,
    HOOKS_BEFORE_SWAP_RETURNS_DELTA_OFFSET,
    HOOKS_AFTER_SWAP_RETURNS_DELTA_OFFSET
} from "infinity-core/src/pool-cl/interfaces/ICLHooks.sol";
import {TickMath} from "infinity-core/src/pool-cl/libraries/TickMath.sol";
import {IAgentId, IMsgSender, IAgentHookContext, PERMANENT} from "./interfaces/IAgentLaunch.sol";
import {IStockHolderRewards, IStockLaunchLookup} from "./interfaces/IStockLaunch.sol";

/// @title StockCurveHook
/// @notice AgentCurveHook for launches paired with a bStock instead of BNB. One PancakeSwap Infinity CL hook for every
///         stock-meme launch: the whole supply sits in a locked single-sided position from the launch price, and the
///         same .ai window, hold-cap window, anti-sniper ladder and tax period apply. The differences:
///         - the base is an ERC20 (an allowlisted bStock), and the meme can be either currency of the pool, because
///           pools sort their currencies by address (`memeIs0` per launch);
///         - every fee is withheld in the bStock and held as Infinity Vault claims (ERC6909), per launch. A swap never
///           moves bStock out of the Vault for fees, so a payout the bStock refuses (paused token, blocked address)
///           can only fail its own payout, never a trade or another launch. Payouts burn the claims and take the bStock
///           in their own Vault lock, and a refused payout stays owed.
contract StockCurveHook is ICLHooks, ILockCallback, IAgentHookContext, IStockLaunchLookup {
    using PoolIdLibrary for PoolKey;
    using BalanceDeltaLibrary for BalanceDelta;
    using SafeERC20 for IERC20;

    // ---- constants ----
    uint256 internal constant BPS = 10_000;
    uint256 internal constant PIPS = 1_000_000;
    /// @notice Base fee on every trade: half to the platform (bStock to `feeSink`, which buys back and burns $SUAN),
    ///         half to the creator (or, once the creator switches it, to holders).
    uint256 public constant BASE_FEE_BPS = 100;
    /// @notice Creator presale in the launch transaction: at most this share of the supply.
    uint256 public constant PRESALE_MAX_BPS = 300;
    /// @notice Max price move allowed for one buyback, as a fraction of sqrtPrice (≈1% price impact).
    uint256 public constant BUYBACK_SQRT_STEP_PIPS = 5_000;
    uint256 internal constant SUPPLY = 1_000_000_000 ether;
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;

    IVault public immutable vault;
    ICLPoolManager public immutable poolManager;
    IAgentId public immutable agentId;
    address public immutable factory;
    address public immutable treasury;
    /// @notice Receives the platform's half of the base fee in bStock (`StockFeeSink`), which converts it to BNB for
    ///         the $SUAN buy-and-burn.
    address public immutable feeSink;
    /// @notice The platform keeper, the only caller of `buyback`. Set by the factory owner.
    address public keeper;

    struct Launch {
        // config (set once)
        PoolKey key;
        address base;
        bool memeIs0;
        address creator;
        address founder;
        address rewards;
        uint64 createBlock;
        uint64 launchTime;
        uint64 aiOnlyUntil;
        uint64 holdCapUntil;
        uint64 taxEnd;
        uint16 buyTaxBps;
        uint16 sellTaxBps;
        uint16 agentBuyTaxBps;
        uint16 agentSellTaxBps;
        uint8 wFounder;
        uint8 wHolder;
        uint8 wBurn;
        uint8 wLiquidity;
        bool antiSniper;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        // state
        bool creatorShareToHolders;
        uint64 lastBuybackBlock;
        // bStock owed (held by the hook as Vault claims), withheld from swaps
        uint256 treasuryOwed;
        uint256 founderOwed;
        uint256 buybackOwed;
        uint256 suanOwed; // platform half of the base fee, paid to `feeSink` by `dispatch`
    }

    struct LaunchConfig {
        address token;
        address base;
        address creator;
        address founder;
        address rewards;
        uint16 buyTaxBps;
        uint16 sellTaxBps;
        uint16 agentBuyTaxBps;
        uint16 agentSellTaxBps;
        uint8 wFounder;
        uint8 wHolder;
        uint8 wBurn;
        uint8 wLiquidity;
        bool antiSniper;
        uint64 aiOnlySeconds;
        uint64 holdCapSeconds;
        uint64 taxSeconds;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
    }

    mapping(address => Launch) internal launches;
    mapping(address => bool) public isTrustedRouter;

    // transient slots (namespaced apart from AgentCurveHook's, although each hook has its own storage)
    uint256 private constant VAULT_IN_SLOT = uint256(keccak256("dotai.stockhook.vault-in"));
    uint256 private constant VAULT_OUT_SLOT = uint256(keccak256("dotai.stockhook.vault-out"));
    uint256 private constant PRESALE_SLOT = uint256(keccak256("dotai.stockhook.presale"));
    uint256 private constant BUY_FEE_SLOT = uint256(keccak256("dotai.stockhook.buy-fee"));
    bytes32 private constant LOCK_SLOT = keccak256("dotai.stockhook.lock");

    enum Action {
        Seed,
        Presale,
        Buyback,
        Pay
    }

    event LaunchRegistered(address indexed token, PoolId indexed poolId, address creator, address base, bool memeIs0);
    /// @dev amounts in the base bStock
    event FeeTaken(address indexed token, address indexed trader, bool isBuy, uint256 base, uint256 tax, uint256 antiSniper);
    /// @notice One per trade in a launch's pool, including the creator presale and buybacks (trader = the hook).
    /// @param baseAmount bStock the trader paid (buy, every fee included) or received (sell, after every fee)
    /// @param sqrtPriceX96 pool price after the trade, in the pool's own orientation (see `memeIsCurrency0`)
    event Swapped(
        address indexed token, address indexed trader, bool isBuy, uint256 baseAmount, uint256 tokenAmount, uint160 sqrtPriceX96
    );
    event BuybackBurned(address indexed token, uint256 baseIn, uint256 tokensBurned);
    /// @notice Emitted by `claimFounder` (founder only) and `dispatch` (treasury).
    event Dispatched(address indexed token, uint256 founder, uint256 holders, uint256 treasury);
    /// @notice Emitted by `dispatch` when the platform's base-fee half reaches `feeSink`.
    event SuanDispatched(address indexed token, uint256 amount);
    /// @notice A payout the bStock refused; the amount stays owed.
    event PayoutFailed(address indexed token, address indexed to, uint256 amount);
    /// @notice The creator sent its base-fee share to holders, for good.
    event CreatorShareToHolders(address indexed token);
    event KeeperSet(address keeper);

    error OnlyPoolManager();
    error OnlyVault();
    error OnlyFactory();
    error UnknownLaunch();
    error NotAgent(address trader);
    error ExactOutputUnsupported();
    error RouterMismatch();
    error PresaleCap(uint256 maxTokens);
    error LiquidityLocked();
    error Reentrant();
    error NotKeeper();
    error NotCreator();
    error BuybackThisBlock();
    error BuybackTooEarly();
    error FounderTransferFailed();

    constructor(
        IVault vault_,
        ICLPoolManager poolManager_,
        address agentId_,
        address factory_,
        address treasury_,
        address feeSink_,
        address[] memory routers
    ) {
        vault = vault_;
        poolManager = poolManager_;
        agentId = IAgentId(agentId_);
        factory = factory_;
        treasury = treasury_;
        feeSink = feeSink_;
        for (uint256 i; i < routers.length; ++i) {
            isTrustedRouter[routers[i]] = true;
        }
    }

    modifier nonReentrant() {
        bytes32 slot = LOCK_SLOT;
        uint256 locked;
        assembly ("memory-safe") {
            locked := tload(slot)
        }
        if (locked != 0) revert Reentrant();
        assembly ("memory-safe") {
            tstore(slot, 1)
        }
        _;
        assembly ("memory-safe") {
            tstore(slot, 0)
        }
    }

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert OnlyPoolManager();
        _;
    }

    // ------------------------------------------------------------------
    // hook permissions
    // ------------------------------------------------------------------

    function getHooksRegistrationBitmap() external pure returns (uint16) {
        return uint16(
            (1 << HOOKS_BEFORE_INITIALIZE_OFFSET) | (1 << HOOKS_BEFORE_ADD_LIQUIDITY_OFFSET) | (1 << HOOKS_BEFORE_SWAP_OFFSET)
                | (1 << HOOKS_AFTER_SWAP_OFFSET) | (1 << HOOKS_BEFORE_DONATE_OFFSET)
                | (1 << HOOKS_BEFORE_SWAP_RETURNS_DELTA_OFFSET) | (1 << HOOKS_AFTER_SWAP_RETURNS_DELTA_OFFSET)
        );
    }

    // ------------------------------------------------------------------
    // factory entry points
    // ------------------------------------------------------------------

    function registerLaunch(PoolKey calldata key, LaunchConfig calldata c) external {
        if (msg.sender != factory) revert OnlyFactory();
        Launch storage l = launches[c.token];
        uint64 t = uint64(block.timestamp);
        l.key = key;
        l.base = c.base;
        l.memeIs0 = Currency.unwrap(key.currency0) == c.token;
        l.creator = c.creator;
        l.founder = c.founder;
        l.rewards = c.rewards;
        l.createBlock = uint64(block.number);
        l.launchTime = t;
        l.aiOnlyUntil = t + c.aiOnlySeconds;
        l.holdCapUntil = t + c.holdCapSeconds;
        l.taxEnd = c.taxSeconds == PERMANENT ? PERMANENT : t + c.taxSeconds;
        l.buyTaxBps = c.buyTaxBps;
        l.sellTaxBps = c.sellTaxBps;
        l.agentBuyTaxBps = c.agentBuyTaxBps;
        l.agentSellTaxBps = c.agentSellTaxBps;
        l.wFounder = c.wFounder;
        l.wHolder = c.wHolder;
        l.wBurn = c.wBurn;
        l.wLiquidity = c.wLiquidity;
        l.antiSniper = c.antiSniper;
        l.tickLower = c.tickLower;
        l.tickUpper = c.tickUpper;
        l.liquidity = c.liquidity;
        emit LaunchRegistered(c.token, key.toId(), c.creator, c.base, l.memeIs0);
    }

    function setKeeper(address keeper_) external {
        if (msg.sender != factory) revert OnlyFactory();
        keeper = keeper_;
        emit KeeperSet(keeper_);
    }

    /// @notice Put the whole supply into the pool's single-sided position. Called by the factory right after `initialize`.
    function seed(address token) external {
        if (msg.sender != factory) revert OnlyFactory();
        vault.lock(abi.encode(Action.Seed, token, uint256(0), address(0)));
    }

    /// @notice Creator presale in the launch transaction: no Agent ID needed, at most 3% of the supply. The factory has
    ///         already moved `amount` of the bStock from the creator to this hook.
    function presale(address token, address creator, uint256 amount) external {
        if (msg.sender != factory) revert OnlyFactory();
        _tstore(PRESALE_SLOT, token, uint256(uint160(creator)));
        vault.lock(abi.encode(Action.Presale, token, amount, creator));
        _tstore(PRESALE_SLOT, token, 0);
    }

    // ------------------------------------------------------------------
    // public entry points
    // ------------------------------------------------------------------

    /// @notice Send the creator's half of the base fee to holders from now on. One-way; the creator calls it once.
    function setCreatorShareToHolders(address token) external {
        Launch storage l = launches[token];
        if (l.launchTime == 0) revert UnknownLaunch();
        if (msg.sender != l.creator) revert NotCreator();
        l.creatorShareToHolders = true;
        emit CreatorShareToHolders(token);
    }

    /// @notice Spend up to `maxBase` of the buyback bucket buying the token in its own pool and burn it. Keeper only,
    ///         once per block per token, after the .ai window, and never past `sqrtPriceLimitX96`, the keeper's bound
    ///         from an earlier block's price, so a front-run that moved the price past it makes the buyback buy nothing.
    ///         A buy moves the pool price down when the bStock is currency0 and up when the meme is (`memeIsCurrency0`):
    ///         the bound is a floor in the first case and a ceiling in the second. 0 = no bound beyond the built-in
    ///         `BUYBACK_SQRT_STEP_PIPS` step.
    function buyback(address token, uint256 maxBase, uint160 sqrtPriceLimitX96)
        external
        nonReentrant
        returns (uint256 spent, uint256 burned)
    {
        if (msg.sender != keeper) revert NotKeeper();
        Launch storage l = launches[token];
        if (l.launchTime == 0) revert UnknownLaunch();
        if (block.timestamp < l.aiOnlyUntil) revert BuybackTooEarly();
        if (l.lastBuybackBlock == block.number) revert BuybackThisBlock();
        l.lastBuybackBlock = uint64(block.number);
        uint256 amount = l.buybackOwed < maxBase ? l.buybackOwed : maxBase;
        if (amount == 0) return (0, 0);
        (uint160 sqrtNow,,,) = poolManager.getSlot0(l.key.toId());
        uint160 limit;
        if (l.memeIs0) {
            // buying the meme (currency0) raises the price
            uint256 step = uint256(sqrtNow) * (PIPS + BUYBACK_SQRT_STEP_PIPS) / PIPS;
            limit = step < TickMath.MAX_SQRT_RATIO ? uint160(step) : TickMath.MAX_SQRT_RATIO - 1;
            if (sqrtPriceLimitX96 != 0 && sqrtPriceLimitX96 < limit) limit = sqrtPriceLimitX96;
            if (sqrtNow >= limit) return (0, 0);
        } else {
            limit = uint160(uint256(sqrtNow) * (PIPS - BUYBACK_SQRT_STEP_PIPS) / PIPS);
            if (sqrtPriceLimitX96 > limit) limit = sqrtPriceLimitX96;
            if (sqrtNow <= limit) return (0, 0);
        }
        bytes memory out = vault.lock(abi.encode(Action.Buyback, token, amount, address(limit)));
        (spent, burned) = abi.decode(out, (uint256, uint256));
        l.buybackOwed -= spent;
        emit BuybackBurned(token, spent, burned);
    }

    /// @notice Pay the treasury and $SUAN buckets out in bStock. Anyone may call. A payout the bStock refuses stays
    ///         owed (and emits `PayoutFailed`); it never reverts the other one or anything else.
    function dispatch(address token) external nonReentrant {
        Launch storage l = launches[token];
        if (l.launchTime == 0) revert UnknownLaunch();
        uint256 t = l.treasuryOwed;
        if (t > 0) {
            l.treasuryOwed = 0;
            if (!_tryPay(token, treasury, t)) {
                l.treasuryOwed = t;
                t = 0;
            }
        }
        uint256 s = l.suanOwed;
        if (s > 0) {
            l.suanOwed = 0;
            if (_tryPay(token, feeSink, s)) emit SuanDispatched(token, s);
            else l.suanOwed = s;
        }
        emit Dispatched(token, 0, 0, t);
    }

    /// @notice Pay the founder bucket to the founder in bStock. Anyone may call; it only ever goes to the founder. A
    ///         founder the bStock refuses only blocks its own payout.
    function claimFounder(address token) external nonReentrant returns (uint256 amount) {
        Launch storage l = launches[token];
        if (l.launchTime == 0) revert UnknownLaunch();
        amount = l.founderOwed;
        if (amount == 0) return 0;
        l.founderOwed = 0;
        if (!_tryPay(token, l.founder, amount)) revert FounderTransferFailed();
        emit Dispatched(token, amount, 0, 0);
    }

    // ------------------------------------------------------------------
    // views
    // ------------------------------------------------------------------

    /// @notice Everything a wallet, terminal or agent skill needs to show and quote a launch, in one call.
    struct LaunchView {
        bool exists;
        address base;
        /// @dev true when the meme is currency0: then `sqrtPriceX96` is bStock per meme, otherwise meme per bStock
        bool memeIsCurrency0;
        address creator;
        address founder;
        address rewards;
        uint64 createBlock;
        uint64 launchTime;
        uint64 aiOnlyUntil;
        uint64 holdCapUntil;
        uint64 taxEnd;
        uint16 buyTaxBps;
        uint16 sellTaxBps;
        uint16 agentBuyTaxBps;
        uint16 agentSellTaxBps;
        /// @dev rates in force right now (after the tax period everyone pays the .ai rate)
        uint16 buyTaxNowBps;
        uint16 sellTaxNowBps;
        uint16 antiSniperBps;
        bool antiSniper;
        bool creatorShareToHolders;
        uint160 sqrtPriceX96;
        uint24 protocolFee;
        uint128 liquidity;
        /// @dev tax split weights (sum 100 when taxed): founder, holder rewards, buyback & burn, liquidity
        uint8 wFounder;
        uint8 wHolder;
        uint8 wBurn;
        uint8 wLiquidity;
    }

    function launchInfo(address token) external view returns (LaunchView memory v) {
        Launch storage l = launches[token];
        if (l.launchTime == 0) return v;
        (uint160 sqrtP,, uint24 protocolFee,) = poolManager.getSlot0(l.key.toId());
        bool taxed = block.timestamp < l.taxEnd;
        v.exists = true;
        v.base = l.base;
        v.memeIsCurrency0 = l.memeIs0;
        v.creator = l.creator;
        v.founder = l.founder;
        v.rewards = l.rewards;
        v.createBlock = l.createBlock;
        v.launchTime = l.launchTime;
        v.aiOnlyUntil = l.aiOnlyUntil;
        v.holdCapUntil = l.holdCapUntil;
        v.taxEnd = l.taxEnd;
        v.buyTaxBps = l.buyTaxBps;
        v.sellTaxBps = l.sellTaxBps;
        v.agentBuyTaxBps = l.agentBuyTaxBps;
        v.agentSellTaxBps = l.agentSellTaxBps;
        v.buyTaxNowBps = taxed ? l.buyTaxBps : l.agentBuyTaxBps;
        v.sellTaxNowBps = taxed ? l.sellTaxBps : l.agentSellTaxBps;
        v.antiSniperBps = uint16(_antiSniperBps(l));
        v.antiSniper = l.antiSniper;
        v.creatorShareToHolders = l.creatorShareToHolders;
        v.sqrtPriceX96 = sqrtP;
        v.protocolFee = protocolFee;
        v.liquidity = poolManager.getLiquidity(l.key.toId());
        v.wFounder = l.wFounder;
        v.wHolder = l.wHolder;
        v.wBurn = l.wBurn;
        v.wLiquidity = l.wLiquidity;
    }

    function poolKeyOf(address token) external view returns (PoolKey memory) {
        return launches[token].key;
    }

    /// @inheritdoc IStockLaunchLookup
    function baseOf(address token) external view returns (address) {
        return launches[token].base;
    }

    /// @dev bStock owed per bucket. Holder rewards never wait in the hook (`holderOwed` is always 0, kept for the same
    ///      shape as AgentCurveHook).
    function owedOf(address token)
        external
        view
        returns (uint256 treasuryOwed, uint256 founderOwed, uint256 holderOwed, uint256 buybackOwed)
    {
        Launch storage l = launches[token];
        return (l.treasuryOwed, l.founderOwed, 0, l.buybackOwed);
    }

    /// @notice bStock of the platform's base-fee half not yet sent to `feeSink`.
    function suanOwedOf(address token) external view returns (uint256) {
        return launches[token].suanOwed;
    }

    /// @inheritdoc IAgentHookContext
    /// @dev Budgets are keyed by the caller, so only a token can spend its own.
    function useVaultFlow(bool inbound, uint256 amount) external returns (bool) {
        uint256 slot = inbound ? VAULT_IN_SLOT : VAULT_OUT_SLOT;
        uint256 budget = _tload(slot, msg.sender);
        if (amount > budget) return false;
        _tstore(slot, msg.sender, budget - amount);
        return true;
    }

    function presaleRecipient(address token) external view returns (address) {
        return address(uint160(_tload(PRESALE_SLOT, token)));
    }

    // ------------------------------------------------------------------
    // ICLHooks
    // ------------------------------------------------------------------

    function beforeInitialize(address sender, PoolKey calldata key, uint160) external view onlyPoolManager returns (bytes4) {
        if (sender != factory) revert OnlyFactory();
        _launchOf(key);
        return this.beforeInitialize.selector;
    }

    /// @dev Only the hook itself adds liquidity, and its own calls never reach here.
    function beforeAddLiquidity(address, PoolKey calldata, ICLPoolManager.ModifyLiquidityParams calldata, bytes calldata)
        external
        view
        onlyPoolManager
        returns (bytes4)
    {
        revert LiquidityLocked();
    }

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        view
        onlyPoolManager
        returns (bytes4)
    {
        revert LiquidityLocked();
    }

    function beforeSwap(address sender, PoolKey calldata key, ICLPoolManager.SwapParams calldata params, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        (Launch storage l, address token) = _launchOf(key);
        if (params.amountSpecified >= 0) revert ExactOutputUnsupported();
        // a buy pays the bStock in: zeroForOne when the bStock is currency0
        bool isBuy = params.zeroForOne != l.memeIs0;

        address trader = tx.origin;
        if (block.timestamp < l.aiOnlyUntil) {
            // the .ai gate checks tx.origin, so a trusted router must be driven by that same wallet
            if (isTrustedRouter[sender] && IMsgSender(sender).msgSender() != trader) revert RouterMismatch();
            if (isBuy && !_isAgent(trader)) revert NotAgent(trader);
        }
        if (!isBuy) return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);

        // Buy: the bStock is the specified (input) currency; withhold the fee from it.
        uint256 amountIn = uint256(-params.amountSpecified);
        uint256 base = amountIn * BASE_FEE_BPS / BPS;
        (uint256 shared, uint256 surcharge) = _tax(l, trader, true, amountIn);
        uint256 tax = shared + surcharge;
        uint256 anti = amountIn * _antiSniperBps(l) / BPS;
        uint256 fee = base + tax + anti;

        _collect(l, base, shared, anti + surcharge);
        _tstore(BUY_FEE_SLOT, token, fee);
        emit FeeTaken(token, trader, true, base, tax, anti);
        return (this.beforeSwap.selector, toBeforeSwapDelta(int128(int256(fee)), 0), 0);
    }

    /// @param hookData optional `abi.encode(recipient)` of a buy during the hold-cap window; default `tx.origin`
    function afterSwap(
        address,
        PoolKey calldata key,
        ICLPoolManager.SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) external onlyPoolManager returns (bytes4, int128) {
        (Launch storage l, address token) = _launchOf(key);
        bool isBuy = params.zeroForOne != l.memeIs0;
        (int128 memeDelta, int128 baseDelta) = l.memeIs0 ? (delta.amount0(), delta.amount1()) : (delta.amount1(), delta.amount0());
        int128 hookDelta;

        if (isBuy) {
            uint256 tokensOut = uint256(uint128(memeDelta));
            if (block.timestamp < l.holdCapUntil) {
                // The hook delivers the tokens as ERC20 itself, so every early buy passes the token's .ai gate and
                // 1% cap, and none can stay in the Vault as claims.
                address to = hookData.length == 32 ? abi.decode(hookData, (address)) : tx.origin;
                _deliver(token, to, tokensOut);
                hookDelta = int128(int256(tokensOut));
            } else {
                _addVaultFlow(VAULT_OUT_SLOT, token, tokensOut);
            }
            uint256 paid = uint256(uint128(-baseDelta)) + _tload(BUY_FEE_SLOT, token);
            _emitSwapped(l, token, tx.origin, true, paid, tokensOut);
        } else {
            uint256 tokensIn = uint256(uint128(-memeDelta));
            _addVaultFlow(VAULT_IN_SLOT, token, tokensIn);
            // Sell: the bStock is the unspecified (output) currency; withhold the fee from what the seller receives.
            uint256 baseOut = uint256(uint128(baseDelta));
            address trader = tx.origin;
            uint256 base = baseOut * BASE_FEE_BPS / BPS;
            (uint256 shared, uint256 surcharge) = _tax(l, trader, false, baseOut);
            uint256 tax = shared + surcharge;
            uint256 fee = base + tax;
            if (fee > 0) {
                _collect(l, base, shared, surcharge);
                hookDelta = int128(int256(fee));
            }
            emit FeeTaken(token, trader, false, base, tax, 0);
            _emitSwapped(l, token, trader, false, baseOut - fee, tokensIn);
        }
        return (this.afterSwap.selector, hookDelta);
    }

    // unused callbacks (not registered in the bitmap)
    function afterInitialize(address, PoolKey calldata, uint160, int24) external pure returns (bytes4) {
        revert();
    }

    function afterAddLiquidity(address, PoolKey calldata, ICLPoolManager.ModifyLiquidityParams calldata, BalanceDelta, BalanceDelta, bytes calldata)
        external
        pure
        returns (bytes4, BalanceDelta)
    {
        revert();
    }

    function beforeRemoveLiquidity(address, PoolKey calldata, ICLPoolManager.ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        revert();
    }

    function afterRemoveLiquidity(address, PoolKey calldata, ICLPoolManager.ModifyLiquidityParams calldata, BalanceDelta, BalanceDelta, bytes calldata)
        external
        pure
        returns (bytes4, BalanceDelta)
    {
        revert();
    }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        revert();
    }

    // ------------------------------------------------------------------
    // vault lock
    // ------------------------------------------------------------------

    function lockAcquired(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(vault)) revert OnlyVault();
        (Action action, address token, uint256 amount, address recipient) = abi.decode(data, (Action, address, uint256, address));
        Launch storage l = launches[token];
        Currency baseC = Currency.wrap(l.base);

        if (action == Action.Pay) {
            // the bStock leaves the Vault only here, one payout per lock
            vault.burn(address(this), baseC, amount);
            vault.take(baseC, recipient, amount);
            return "";
        }
        if (action == Action.Seed) {
            poolManager.modifyLiquidity(
                l.key,
                ICLPoolManager.ModifyLiquidityParams({
                    tickLower: l.tickLower, tickUpper: l.tickUpper, liquidityDelta: int256(uint256(l.liquidity)), salt: 0
                }),
                ""
            );
            _settleSeed(token);
            return "";
        }
        bool buyZeroForOne = !l.memeIs0;
        if (action == Action.Presale) {
            // fees as for a buy by the creator's identity, without anti-sniper (same block as the launch)
            uint256 base = amount * BASE_FEE_BPS / BPS;
            (uint256 shared, uint256 surcharge) = _tax(l, recipient, true, amount);
            uint256 tax = shared + surcharge;
            _collect(l, base, shared, surcharge);
            BalanceDelta d = poolManager.swap(
                l.key,
                ICLPoolManager.SwapParams({
                    zeroForOne: buyZeroForOne,
                    amountSpecified: -int256(amount - base - tax),
                    sqrtPriceLimitX96: buyZeroForOne ? TickMath.MIN_SQRT_RATIO + 1 : TickMath.MAX_SQRT_RATIO - 1
                }),
                ""
            );
            (uint256 paid, uint256 bought) = _buyAmounts(l, d);
            uint256 maxTokens = SUPPLY * PRESALE_MAX_BPS / BPS;
            if (bought > maxTokens) revert PresaleCap(maxTokens);
            // pay the swap and the fee claims minted above out of the presale bStock the factory sent here
            _settleBase(l.base, paid + base + tax);
            _deliver(token, recipient, bought);
            uint256 left = amount - paid - base - tax;
            if (left > 0) IERC20(l.base).safeTransfer(recipient, left);
            emit FeeTaken(token, recipient, true, base, tax, 0);
            _emitSwapped(l, token, recipient, true, amount - left, bought);
            return "";
        }
        // Buyback: the hook's own swap skips its callbacks, so no fee and no gate apply. `recipient` carries the limit.
        BalanceDelta bd = poolManager.swap(
            l.key,
            ICLPoolManager.SwapParams({
                zeroForOne: buyZeroForOne, amountSpecified: -int256(amount), sqrtPriceLimitX96: uint160(recipient)
            }),
            ""
        );
        (uint256 spent, uint256 got) = _buyAmounts(l, bd);
        vault.burn(address(this), baseC, spent); // paid from the launch's buyback claims
        _deliver(token, DEAD, got);
        _emitSwapped(l, token, address(this), true, spent, got);
        return abi.encode(spent, got);
    }

    // ------------------------------------------------------------------
    // internal
    // ------------------------------------------------------------------

    function _launchOf(PoolKey calldata key) private view returns (Launch storage l, address token) {
        token = Currency.unwrap(key.currency1);
        l = launches[token];
        if (l.launchTime != 0) return (l, token);
        token = Currency.unwrap(key.currency0);
        l = launches[token];
        if (l.launchTime == 0) revert UnknownLaunch();
    }

    /// @dev bStock paid in and meme tokens received by a buy, whichever side each is on.
    function _buyAmounts(Launch storage l, BalanceDelta d) private view returns (uint256 paid, uint256 bought) {
        (int128 memeDelta, int128 baseDelta) = l.memeIs0 ? (d.amount0(), d.amount1()) : (d.amount1(), d.amount0());
        paid = uint256(uint128(-baseDelta));
        bought = uint256(uint128(memeDelta));
    }

    /// @dev Pay the position's tokens from the hook's minted supply; burn the rounding dust the position did not take.
    function _settleSeed(address token) private {
        Currency tokenC = Currency.wrap(token);
        int256 owed = vault.currencyDelta(address(this), tokenC);
        if (owed < 0) {
            vault.sync(tokenC);
            IERC20(token).safeTransfer(address(vault), uint256(-owed));
            vault.settle();
        }
        uint256 dust = IERC20(token).balanceOf(address(this));
        if (dust > 0) IERC20(token).safeTransfer(DEAD, dust);
    }

    function _settleBase(address base, uint256 amount) private {
        Currency c = Currency.wrap(base);
        vault.sync(c);
        IERC20(base).safeTransfer(address(vault), amount);
        vault.settle();
    }

    /// @dev Withhold a fee as Vault claims of the bStock: the holder share is minted straight to the launch's
    ///      HolderRewards (and distributed there with this trade), the rest to the hook, booked per bucket.
    ///      Base fee: platform half to the $SUAN bucket; creator half to the founder, or to holders once the creator
    ///      switched it. `tax` (the .ai-rate part): split by the launch's weights. `toBuyback` (the anti-sniper
    ///      surcharge and the 3-point surcharge of wallets without .ai): all to the token's own buyback.
    function _collect(Launch storage l, uint256 base, uint256 tax, uint256 toBuyback) private {
        uint256 creatorShare = base / 2;
        uint256 holder;
        if (l.creatorShareToHolders) holder = creatorShare;
        else l.founderOwed += creatorShare;
        l.suanOwed += base - creatorShare;
        l.buybackOwed += toBuyback;
        uint256 kept = base - holder + toBuyback;
        if (tax > 0) {
            uint256 total = uint256(l.wFounder) + l.wHolder + l.wBurn + l.wLiquidity;
            if (total == 0) {
                l.treasuryOwed += tax;
            } else {
                uint256 founder = tax * l.wFounder / total;
                uint256 toHolders = tax * l.wHolder / total;
                uint256 burn = tax * l.wBurn / total;
                l.founderOwed += founder;
                holder += toHolders;
                l.buybackOwed += burn;
                l.treasuryOwed += tax - founder - toHolders - burn; // liquidity share: to the platform treasury
                tax -= toHolders;
            }
            kept += tax;
        }
        Currency baseC = Currency.wrap(l.base);
        if (kept > 0) vault.mint(address(this), baseC, kept);
        if (holder > 0) {
            vault.mint(l.rewards, baseC, holder);
            IStockHolderRewards(l.rewards).notifyReward(holder);
        }
    }

    /// @dev Tax on `amount`: everyone pays the .ai rate (`shared`, split by the launch's weights); during the tax period
    ///      wallets without .ai also pay the gap to the normal rate (`surcharge`, 3 points, all to buyback & burn).
    function _tax(Launch storage l, address trader, bool isBuy, uint256 amount)
        private
        view
        returns (uint256 shared, uint256 surcharge)
    {
        uint256 aiBps = isBuy ? l.agentBuyTaxBps : l.agentSellTaxBps;
        shared = amount * aiBps / BPS;
        if (block.timestamp >= l.taxEnd || _isAgent(trader)) return (shared, 0);
        uint256 normalBps = isBuy ? l.buyTaxBps : l.sellTaxBps;
        surcharge = amount * (normalBps - aiBps) / BPS;
    }

    /// @dev four.meme's BSC ladder by block offset from creation (target total surcharge), minus the base fee already
    ///      charged. From block 6 nothing extra is taken.
    function _antiSniperBps(Launch storage l) private view returns (uint256) {
        if (!l.antiSniper) return 0;
        uint256 offset = block.number - l.createBlock;
        uint256 target;
        if (offset == 0) target = 10_000;
        else if (offset == 1) target = 5_000;
        else if (offset == 2) target = 2_500;
        else if (offset == 3) target = 1_500;
        else if (offset == 4) target = 1_000;
        else if (offset == 5) target = 500;
        else return 0;
        return target - BASE_FEE_BPS;
    }

    function _emitSwapped(Launch storage l, address token, address trader, bool isBuy, uint256 baseAmount, uint256 tokens)
        private
    {
        (uint160 sqrtP,,,) = poolManager.getSlot0(l.key.toId());
        emit Swapped(token, trader, isBuy, baseAmount, tokens, sqrtP);
    }

    /// @dev Take `amount` of `token` out of the Vault to `to`, covering exactly that transfer with Vault budget.
    function _deliver(address token, address to, uint256 amount) private {
        _addVaultFlow(VAULT_OUT_SLOT, token, amount);
        vault.take(Currency.wrap(token), to, amount);
    }

    /// @dev One payout in its own Vault lock: burn `amount` of the hook's claims and take the bStock to `to`. False when
    ///      the bStock refuses the transfer (or anything else in that lock fails); nothing changes then.
    function _tryPay(address token, address to, uint256 amount) private returns (bool ok) {
        try vault.lock(abi.encode(Action.Pay, token, amount, to)) {
            ok = true;
        } catch {
            emit PayoutFailed(token, to, amount);
        }
    }

    function _addVaultFlow(uint256 slot, address token, uint256 amount) private {
        _tstore(slot, token, _tload(slot, token) + amount);
    }

    function _isAgent(address account) private view returns (bool) {
        return agentId.balanceOf(account) > 0;
    }

    function _tstore(uint256 slot, address token, uint256 value) private {
        bytes32 key = keccak256(abi.encode(slot, token));
        assembly ("memory-safe") {
            tstore(key, value)
        }
    }

    function _tload(uint256 slot, address token) private view returns (uint256 value) {
        bytes32 key = keccak256(abi.encode(slot, token));
        assembly ("memory-safe") {
            value := tload(key)
        }
    }
}
