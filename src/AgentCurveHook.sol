// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "infinity-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "infinity-core/src/types/Currency.sol";
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
import {IAgentId, IMsgSender, IAgentHookContext, IHolderRewards, PERMANENT} from "./interfaces/IAgentLaunch.sol";

/// @title AgentCurveHook
/// @notice One PancakeSwap Infinity CL hook for every launch. Each token trades in one pool from its first block:
///         the whole supply is a single-sided position from the launch price up, locked forever, so there is no
///         bonding-curve phase and no graduation. What changes over time is set at launch:
///         - .ai window: only wallets holding a .ai Agent ID may buy;
///         - hold-cap window: the hook delivers buys itself so the token can enforce the 1% cap;
///         - tax period: .ai wallets pay the .ai tax rate, everyone else the normal rate; afterwards everyone pays the
///           .ai rate.
///         Every fee is withheld in BNB on the swap itself.
contract AgentCurveHook is ICLHooks, ILockCallback, IAgentHookContext {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using BalanceDeltaLibrary for BalanceDelta;

    // ---- constants ----
    uint256 internal constant BPS = 10_000;
    uint256 internal constant PIPS = 1_000_000;
    /// @notice Base fee on every trade: half to the platform, which buys back and burns $SUAN with it, half to the
    ///         creator (or, once the creator switches it, to holders).
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
    /// @notice Receives the platform's half of the base fee (and the factory's launch fee) to buy back and burn $SUAN.
    address public immutable suanSink;
    /// @notice The platform keeper, the only caller of `buyback`. Set by the factory owner.
    address public keeper;

    struct Launch {
        // config (set once)
        PoolKey key;
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
        // BNB owed, withheld from swaps
        uint256 treasuryOwed;
        uint256 founderOwed;
        uint256 holderOwed; // deposited into HolderRewards at the end of the same trade
        uint256 buybackOwed;
        uint256 suanOwed; // platform half of the base fee, paid to `suanSink` by `dispatch`
    }

    struct LaunchConfig {
        address token;
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

    // transient slots
    /// @dev Per-token ERC20 amounts that may enter / leave the Vault in this transaction, credited only by swaps in the
    ///      token's own pool (see `useVaultFlow`). A per-transaction "pool is active" flag is not enough: once set, it
    ///      would also cover transfers that pay for other pools inside the same Vault lock.
    uint256 private constant VAULT_IN_SLOT = uint256(keccak256("dotai.hook.vault-in"));
    uint256 private constant VAULT_OUT_SLOT = uint256(keccak256("dotai.hook.vault-out"));
    uint256 private constant PRESALE_SLOT = uint256(keccak256("dotai.hook.presale"));
    /// @dev Fee a buy paid in `beforeSwap`, read back in `afterSwap` for the `Swapped` event.
    uint256 private constant BUY_FEE_SLOT = uint256(keccak256("dotai.hook.buy-fee"));
    /// @dev Reentrancy lock of the payout entry points (buyback, dispatch, claimFounder).
    bytes32 private constant LOCK_SLOT = keccak256("dotai.hook.lock");

    enum Action {
        Seed,
        Presale,
        Buyback
    }

    event LaunchRegistered(address indexed token, PoolId indexed poolId, address creator);
    event FeeTaken(address indexed token, address indexed trader, bool isBuy, uint256 base, uint256 tax, uint256 antiSniper);
    /// @notice One per trade in a launch's pool, including the creator presale and buybacks (trader = the hook).
    /// @param bnbAmount BNB the trader paid (buy, every fee included) or received (sell, after every fee)
    /// @param sqrtPriceX96 pool price after the trade (tokens per BNB)
    event Swapped(
        address indexed token, address indexed trader, bool isBuy, uint256 bnbAmount, uint256 tokenAmount, uint160 sqrtPriceX96
    );
    event BuybackBurned(address indexed token, uint256 bnbIn, uint256 tokensBurned);
    /// @notice Emitted by `claimFounder` (founder only) and `dispatch` (treasury, plus any holder remainder).
    event Dispatched(address indexed token, uint256 founder, uint256 holders, uint256 treasury);
    /// @notice Emitted by `dispatch` when the platform's base-fee half reaches `suanSink`.
    event SuanDispatched(address indexed token, uint256 amount);
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
        address suanSink_,
        address[] memory routers
    ) {
        vault = vault_;
        poolManager = poolManager_;
        agentId = IAgentId(agentId_);
        factory = factory_;
        treasury = treasury_;
        suanSink = suanSink_;
        for (uint256 i; i < routers.length; ++i) {
            isTrustedRouter[routers[i]] = true;
        }
    }

    receive() external payable {}

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
        emit LaunchRegistered(c.token, key.toId(), c.creator);
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

    /// @notice Creator presale in the launch transaction: no Agent ID needed, at most 3% of the supply.
    function presale(address token, address creator) external payable {
        if (msg.sender != factory) revert OnlyFactory();
        _tstore(PRESALE_SLOT, token, uint256(uint160(creator)));
        vault.lock(abi.encode(Action.Presale, token, msg.value, creator));
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

    /// @notice Spend up to `maxBnb` of the buyback bucket buying the token in its own pool and burn it. Keeper only,
    ///         once per block per token, after the .ai window, and never below `minSqrtPriceX96` (the keeper's floor
    ///         from an earlier block's price), so a buyback cannot be pulled into a sandwich: a front-run that moved the
    ///         price past the floor makes it buy nothing.
    function buyback(address token, uint256 maxBnb, uint160 minSqrtPriceX96)
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
        uint256 amount = l.buybackOwed < maxBnb ? l.buybackOwed : maxBnb;
        if (amount == 0) return (0, 0);
        (uint160 sqrtNow,,,) = poolManager.getSlot0(l.key.toId());
        uint160 limit = uint160(uint256(sqrtNow) * (PIPS - BUYBACK_SQRT_STEP_PIPS) / PIPS);
        if (minSqrtPriceX96 > limit) limit = minSqrtPriceX96;
        if (sqrtNow <= limit) return (0, 0);
        bytes memory out = vault.lock(abi.encode(Action.Buyback, token, amount, address(uint160(limit))));
        (spent, burned) = abi.decode(out, (uint256, uint256));
        l.buybackOwed -= spent;
        emit BuybackBurned(token, spent, burned);
    }

    /// @notice Pay the treasury and $SUAN buckets (and any holder remainder) out. Anyone may call.
    function dispatch(address token) external nonReentrant {
        Launch storage l = launches[token];
        if (l.launchTime == 0) revert UnknownLaunch();
        uint256 h = _flushHolders(l);
        uint256 t = l.treasuryOwed;
        if (t > 0) {
            l.treasuryOwed = 0;
            if (!_sendNative(treasury, t)) {
                l.treasuryOwed = t;
                t = 0;
            }
        }
        uint256 s = l.suanOwed;
        if (s > 0) {
            l.suanOwed = 0;
            if (_sendNative(suanSink, s)) emit SuanDispatched(token, s);
            else l.suanOwed = s;
        }
        emit Dispatched(token, 0, h, t);
    }

    /// @notice Pay the founder bucket to the founder. Anyone may call; the BNB only ever goes to the founder. A founder
    ///         that refuses BNB only blocks its own payout.
    function claimFounder(address token) external nonReentrant returns (uint256 amount) {
        Launch storage l = launches[token];
        if (l.launchTime == 0) revert UnknownLaunch();
        amount = l.founderOwed;
        if (amount == 0) return 0;
        l.founderOwed = 0;
        if (!_sendNative(l.founder, amount)) revert FounderTransferFailed();
        emit Dispatched(token, amount, 0, 0);
    }

    // ------------------------------------------------------------------
    // views
    // ------------------------------------------------------------------

    /// @notice Everything a wallet, terminal or agent skill needs to show and quote a launch, in one call.
    struct LaunchView {
        bool exists;
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

    function owedOf(address token)
        external
        view
        returns (uint256 treasuryOwed, uint256 founderOwed, uint256 holderOwed, uint256 buybackOwed)
    {
        Launch storage l = launches[token];
        return (l.treasuryOwed, l.founderOwed, l.holderOwed, l.buybackOwed);
    }

    /// @notice BNB of the platform's base-fee half not yet sent to `suanSink`.
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
        if (launches[Currency.unwrap(key.currency1)].launchTime == 0) revert UnknownLaunch();
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
        address token = Currency.unwrap(key.currency1);
        Launch storage l = launches[token];
        if (l.launchTime == 0) revert UnknownLaunch();
        if (params.amountSpecified >= 0) revert ExactOutputUnsupported();

        address trader = tx.origin;
        if (block.timestamp < l.aiOnlyUntil) {
            // the .ai gate checks tx.origin, so a trusted router must be driven by that same wallet
            if (isTrustedRouter[sender] && IMsgSender(sender).msgSender() != trader) revert RouterMismatch();
            if (params.zeroForOne && !_isAgent(trader)) revert NotAgent(trader);
        }
        if (!params.zeroForOne) return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);

        // Buy: BNB is the specified (input) currency; withhold the fee from it.
        uint256 amountIn = uint256(-params.amountSpecified);
        uint256 base = amountIn * BASE_FEE_BPS / BPS;
        (uint256 shared, uint256 surcharge) = _tax(l, trader, true, amountIn);
        uint256 tax = shared + surcharge;
        uint256 anti = amountIn * _antiSniperBps(l) / BPS;
        uint256 fee = base + tax + anti;

        vault.take(CurrencyLibrary.NATIVE, address(this), fee);
        _book(l, base, shared, anti + surcharge);
        _flushHolders(l);
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
        address token = Currency.unwrap(key.currency1);
        Launch storage l = launches[token];
        int128 hookDelta;

        if (params.zeroForOne) {
            uint256 tokensOut = uint256(uint128(delta.amount1()));
            if (block.timestamp < l.holdCapUntil) {
                // The hook delivers the tokens as ERC20 itself, so every early buy passes the token's .ai gate and
                // 1% cap, and none can stay in the Vault as claims.
                address to = hookData.length == 32 ? abi.decode(hookData, (address)) : tx.origin;
                _deliver(token, to, tokensOut);
                hookDelta = int128(int256(tokensOut));
            } else {
                _addVaultFlow(VAULT_OUT_SLOT, token, tokensOut);
            }
            uint256 paid = uint256(uint128(-delta.amount0())) + _tload(BUY_FEE_SLOT, token);
            _emitSwapped(l, token, tx.origin, true, paid, tokensOut);
        } else {
            _addVaultFlow(VAULT_IN_SLOT, token, uint256(uint128(-delta.amount1())));
            // Sell: BNB is the unspecified (output) currency; withhold the fee from what the seller receives.
            uint256 bnbOut = uint256(uint128(delta.amount0()));
            address trader = tx.origin;
            uint256 base = bnbOut * BASE_FEE_BPS / BPS;
            (uint256 shared, uint256 surcharge) = _tax(l, trader, false, bnbOut);
            uint256 tax = shared + surcharge;
            uint256 fee = base + tax;
            if (fee > 0) {
                vault.take(CurrencyLibrary.NATIVE, address(this), fee);
                _book(l, base, shared, surcharge);
                _flushHolders(l);
                hookDelta = int128(int256(fee));
            }
            emit FeeTaken(token, trader, false, base, tax, 0);
            _emitSwapped(l, token, trader, false, bnbOut - fee, uint256(uint128(-delta.amount1())));
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

        if (action == Action.Seed) {
            poolManager.modifyLiquidity(
                l.key,
                ICLPoolManager.ModifyLiquidityParams({
                    tickLower: l.tickLower, tickUpper: l.tickUpper, liquidityDelta: int256(uint256(l.liquidity)), salt: 0
                }),
                ""
            );
            _settleSeed(l);
            return "";
        }
        if (action == Action.Presale) {
            // fees as for a buy by the creator's identity, without anti-sniper (same block as the launch)
            uint256 base = amount * BASE_FEE_BPS / BPS;
            (uint256 shared, uint256 surcharge) = _tax(l, recipient, true, amount);
            uint256 tax = shared + surcharge;
            _book(l, base, shared, surcharge);
            _flushHolders(l);
            BalanceDelta d = poolManager.swap(
                l.key,
                ICLPoolManager.SwapParams({
                    zeroForOne: true, amountSpecified: -int256(amount - base - tax), sqrtPriceLimitX96: TickMath.MIN_SQRT_RATIO + 1
                }),
                ""
            );
            uint256 bought = uint256(uint128(d.amount1()));
            uint256 maxTokens = SUPPLY * PRESALE_MAX_BPS / BPS;
            if (bought > maxTokens) revert PresaleCap(maxTokens);
            vault.settle{value: uint256(uint128(-d.amount0()))}();
            _deliver(token, recipient, bought);
            emit FeeTaken(token, recipient, true, base, tax, 0);
            _emitSwapped(l, token, recipient, true, amount, bought);
            return "";
        }
        // Buyback: the hook's own swap skips its callbacks, so no fee and no gate apply. `recipient` carries the limit.
        uint160 limit = uint160(recipient);
        BalanceDelta bd = poolManager.swap(
            l.key, ICLPoolManager.SwapParams({zeroForOne: true, amountSpecified: -int256(amount), sqrtPriceLimitX96: limit}), ""
        );
        uint256 spent = uint256(uint128(-bd.amount0()));
        uint256 got = uint256(uint128(bd.amount1()));
        vault.settle{value: spent}();
        _deliver(token, DEAD, got);
        _emitSwapped(l, token, address(this), true, spent, got);
        return abi.encode(spent, got);
    }

    // ------------------------------------------------------------------
    // internal
    // ------------------------------------------------------------------

    /// @dev Pay the position's tokens from the hook's minted supply; burn the rounding dust the position did not take.
    function _settleSeed(Launch storage l) private {
        Currency tokenC = l.key.currency1;
        address token = Currency.unwrap(tokenC);
        int256 owed = vault.currencyDelta(address(this), tokenC);
        if (owed < 0) {
            vault.sync(tokenC);
            IERC20(token).transfer(address(vault), uint256(-owed));
            vault.settle();
        }
        uint256 dust = IERC20(token).balanceOf(address(this));
        if (dust > 0) IERC20(token).transfer(DEAD, dust);
    }

    /// @dev Base fee: platform half to the $SUAN buyback; creator half to the founder, or to holders once the creator
    ///      switched it. `tax` (the .ai-rate part): split by the launch's weights. `toBuyback` (the
    ///      anti-sniper surcharge and the 3-point surcharge of wallets without .ai): all to buyback & burn, so a creator
    ///      cannot recover it by buying through its own wallets.
    function _book(Launch storage l, uint256 base, uint256 tax, uint256 toBuyback) private {
        uint256 creatorShare = base / 2;
        if (l.creatorShareToHolders) l.holderOwed += creatorShare;
        else l.founderOwed += creatorShare;
        l.suanOwed += base - creatorShare;
        l.buybackOwed += toBuyback;
        if (tax == 0) return;
        uint256 total = uint256(l.wFounder) + l.wHolder + l.wBurn + l.wLiquidity;
        if (total == 0) {
            l.treasuryOwed += tax;
            return;
        }
        uint256 founder = tax * l.wFounder / total;
        uint256 holder = tax * l.wHolder / total;
        uint256 burn = tax * l.wBurn / total;
        l.founderOwed += founder;
        l.holderOwed += holder;
        l.buybackOwed += burn;
        l.treasuryOwed += tax - founder - holder - burn; // liquidity share: to the platform treasury
    }

    /// @dev Holder rewards go into HolderRewards with the trade that paid them, so no one can time a payout.
    function _flushHolders(Launch storage l) private returns (uint256 h) {
        h = l.holderOwed;
        if (h == 0) return 0;
        l.holderOwed = 0;
        IHolderRewards(l.rewards).deposit{value: h}();
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

    function _emitSwapped(Launch storage l, address token, address trader, bool isBuy, uint256 bnb, uint256 tokens) private {
        (uint160 sqrtP,,,) = poolManager.getSlot0(l.key.toId());
        emit Swapped(token, trader, isBuy, bnb, tokens, sqrtP);
    }

    /// @dev Take `amount` of `token` out of the Vault to `to`, covering exactly that transfer with Vault budget.
    function _deliver(address token, address to, uint256 amount) private {
        _addVaultFlow(VAULT_OUT_SLOT, token, amount);
        vault.take(Currency.wrap(token), to, amount);
    }

    function _addVaultFlow(uint256 slot, address token, uint256 amount) private {
        _tstore(slot, token, _tload(slot, token) + amount);
    }

    function _isAgent(address account) private view returns (bool) {
        return agentId.balanceOf(account) > 0;
    }

    /// @dev Return data is never copied, so a receiver cannot make the caller pay for a return bomb.
    function _sendNative(address to, uint256 amount) private returns (bool ok) {
        assembly ("memory-safe") {
            ok := call(gas(), to, amount, 0, 0, 0, 0)
        }
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
