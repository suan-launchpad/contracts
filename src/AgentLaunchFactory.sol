// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "infinity-core/src/types/Currency.sol";
import {IHooks} from "infinity-core/src/interfaces/IHooks.sol";
import {IVault} from "infinity-core/src/interfaces/IVault.sol";
import {IPoolManager} from "infinity-core/src/interfaces/IPoolManager.sol";
import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {LPFeeLibrary} from "infinity-core/src/libraries/LPFeeLibrary.sol";
import {TickMath} from "infinity-core/src/pool-cl/libraries/TickMath.sol";
import {LiquidityAmounts} from "infinity-periphery/src/pool-cl/libraries/LiquidityAmounts.sol";
import {FixedPointMathLib} from "solmate/src/utils/FixedPointMathLib.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {AgentToken} from "./AgentToken.sol";
import {AgentCurveHook} from "./AgentCurveHook.sol";
import {PERMANENT} from "./interfaces/IAgentLaunch.sol";

/// @title AgentLaunchFactory
/// @notice Anyone launches a .ai token here: token + hooked PancakeSwap Infinity pool holding the whole supply as a
///         locked single-sided position + optional creator presale, all in one transaction. The token trades from its
///         first block; there is no bonding-curve phase and no graduation.
contract AgentLaunchFactory is Ownable2Step {
    uint256 public constant SUPPLY = 1_000_000_000 ether;
    /// @notice Market cap at the launch price (four.meme's curve starts at about the same).
    uint256 public constant START_MCAP = 4.2 ether;
    uint256 public constant MIN_SHARE_FLOOR = 10_000 ether;
    uint16 public constant MAX_TAX_BPS = 1_000;
    /// @notice Wallets without a .ai Agent ID always pay this much more tax than .ai wallets, during the tax period.
    uint16 public constant NORMAL_SURCHARGE_BPS = 300;
    /// @notice .ai-only window after launch: at least 2, at most 30 minutes.
    uint64 public constant MIN_AI_ONLY = 2 minutes;
    uint64 public constant MAX_AI_ONLY = 30 minutes;
    /// @notice 1% hold-cap window: at least the .ai window, at most a day.
    uint64 public constant MAX_HOLD_CAP = 1 days;
    /// @notice Tax period (identity tax + no alternative pools): at least 15 days, at most a year, or `PERMANENT`.
    uint64 public constant MIN_TAX_PERIOD = 15 days;
    uint64 public constant MAX_TAX_PERIOD = 365 days;
    /// @notice Longest metadata reference a launch may store (an IPFS CID is 46-59 bytes).
    uint256 public constant MAX_META_BYTES = 128;
    int24 public constant TICK_SPACING = 10;
    uint256 internal constant Q96 = 2 ** 96;

    IVault public immutable vault;
    ICLPoolManager public immutable poolManager;
    address public immutable agentId;
    address public immutable altPoolManager;
    AgentCurveHook public immutable hook;
    /// @notice One-time BNB fee per launch, sent to the hook's `suanSink` out of `msg.value` to buy back and burn $SUAN (0.005 BNB).
    uint256 public immutable launchFee;
    /// @notice Whether anyone may create. Deployed closed: only the owner (the platform) launches until it opens.
    ///         Gates new launches only; existing tokens keep trading and paying rewards regardless.
    bool public launchesOpen;

    struct CreateParams {
        string name;
        string symbol;
        string meta; // IPFS CID of the token's image, description and links (empty allowed)
        address founder; // zero = creator
        uint16 buyTaxBps; // normal rate: always the .ai rate + 3 points (`normalRate`)
        uint16 sellTaxBps;
        uint16 agentBuyTaxBps; // .ai rate, set by the creator (≥ 0); everyone's rate after the tax period
        uint16 agentSellTaxBps;
        uint8 wFounder;
        uint8 wHolder;
        uint8 wBurn;
        uint8 wLiquidity;
        uint256 minShare;
        bool agentOnlyRewards;
        bool antiSniper;
        uint64 aiOnlySeconds; // UI default 2 minutes
        uint64 holdCapSeconds; // UI default 1 hour
        uint64 taxSeconds; // UI default 15 days, or PERMANENT
    }

    event LaunchesOpened(bool open);

    event TokenLaunched(
        address indexed token,
        address indexed creator,
        address rewards,
        string name,
        string symbol,
        string meta
    );

    error InvalidTax();
    error InvalidWeights();
    error InvalidMinShare();
    error InvalidAiOnly();
    error InvalidHoldCap();
    error InvalidTaxPeriod();
    error InvalidMeta();
    error LaunchFeeRequired(uint256 fee);
    error LaunchesClosed();
    error LaunchFeeTransferFailed();

    constructor(
        IVault vault_,
        ICLPoolManager poolManager_,
        address agentId_,
        address altPoolManager_,
        address treasury,
        address suanSink,
        address[] memory trustedRouters,
        uint256 launchFee_
    ) Ownable(msg.sender) {
        vault = vault_;
        poolManager = poolManager_;
        agentId = agentId_;
        altPoolManager = altPoolManager_;
        launchFee = launchFee_;
        hook = new AgentCurveHook(vault_, poolManager_, agentId_, address(this), treasury, suanSink, trustedRouters);
    }

    /// @notice Open (or close again) creation to everyone. The owner can always create.
    function setLaunchesOpen(bool open) external onlyOwner {
        launchesOpen = open;
        emit LaunchesOpened(open);
    }

    /// @notice Set the keeper allowed to run buybacks.
    function setKeeper(address keeper) external onlyOwner {
        hook.setKeeper(keeper);
    }

    /// @param p launch parameters; `msg.value` is `launchFee` plus the creator presale budget (fee-inclusive; the
    ///          tokens it buys must stay within 3% of the supply)
    function create(CreateParams calldata p) external payable returns (AgentToken) {
        if (!launchesOpen && msg.sender != owner()) revert LaunchesClosed();
        return _create(p);
    }

    /// @notice The platform's first launch and the opening of creation to everyone, in one transaction.
    function createAndOpen(CreateParams calldata p) external payable onlyOwner returns (AgentToken token) {
        token = _create(p);
        launchesOpen = true;
        emit LaunchesOpened(true);
    }

    function _create(CreateParams calldata p) private returns (AgentToken token) {
        if (msg.value < launchFee) revert LaunchFeeRequired(launchFee);
        uint256 presaleBudget = msg.value - launchFee;
        _validate(p);

        token = _deployToken(p);
        (PoolKey memory key, uint160 startPrice) = _register(p, token);
        poolManager.initialize(key, startPrice);
        hook.seed(address(token));
        if (launchFee > 0) {
            (bool ok,) = hook.suanSink().call{value: launchFee}("");
            if (!ok) revert LaunchFeeTransferFailed();
        }
        if (presaleBudget > 0) hook.presale{value: presaleBudget}(address(token), msg.sender);

        emit TokenLaunched(address(token), msg.sender, address(token.rewards()), p.name, p.symbol, p.meta);
    }

    function _deployToken(CreateParams calldata p) private returns (AgentToken) {
        return new AgentToken(
            AgentToken.Config({
                name: p.name,
                symbol: p.symbol,
                meta: p.meta,
                hook: address(hook),
                creator: msg.sender,
                vault: address(vault),
                altPoolManager: altPoolManager,
                agentId: agentId,
                aiOnlySeconds: p.aiOnlySeconds,
                holdCapSeconds: p.holdCapSeconds,
                taxSeconds: p.taxSeconds,
                minShare: p.minShare,
                agentOnlyRewards: p.agentOnlyRewards
            })
        );
    }

    function _register(CreateParams calldata p, AgentToken token) private returns (PoolKey memory key, uint160 startPrice) {
        (int24 tickLower, int24 tickUpper, uint128 liquidity) = position();
        key = PoolKey({
            currency0: CurrencyLibrary.NATIVE,
            currency1: Currency.wrap(address(token)),
            hooks: IHooks(address(hook)),
            poolManager: IPoolManager(address(poolManager)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            parameters: bytes32(uint256(hook.getHooksRegistrationBitmap()) | (uint256(uint24(TICK_SPACING)) << 16))
        });
        AgentCurveHook.LaunchConfig memory c;
        c.token = address(token);
        c.creator = msg.sender;
        c.founder = p.founder == address(0) ? msg.sender : p.founder;
        c.rewards = address(token.rewards());
        c.buyTaxBps = p.buyTaxBps;
        c.sellTaxBps = p.sellTaxBps;
        c.agentBuyTaxBps = p.agentBuyTaxBps;
        c.agentSellTaxBps = p.agentSellTaxBps;
        c.wFounder = p.wFounder;
        c.wHolder = p.wHolder;
        c.wBurn = p.wBurn;
        c.wLiquidity = p.wLiquidity;
        c.antiSniper = p.antiSniper;
        c.aiOnlySeconds = p.aiOnlySeconds;
        c.holdCapSeconds = p.holdCapSeconds;
        c.taxSeconds = p.taxSeconds;
        c.tickLower = tickLower;
        c.tickUpper = tickUpper;
        c.liquidity = liquidity;
        hook.registerLaunch(key, c);
        startPrice = TickMath.getSqrtRatioAtTick(tickUpper);
    }

    /// @notice The single-sided position holding the whole supply. Price is tokens per BNB (BNB is currency0), so
    ///         buying moves it down: trading starts at `tickUpper` (market cap `START_MCAP`) and the position reaches
    ///         down to the lowest usable tick, so there is liquidity at every higher token price. Same shape as a
    ///         constant-product curve with `START_MCAP` of virtual BNB.
    function position() public pure returns (int24 tickLower, int24 tickUpper, uint128 liquidity) {
        // sqrt(tokens per BNB) · 2^96, computed as sqrt(SUPPLY · 2^96 / START_MCAP) · 2^48 to stay within 256 bits
        uint160 sqrtStart = uint160(FixedPointMathLib.sqrt(SUPPLY * Q96 / START_MCAP) << 48);
        tickUpper = _floor(TickMath.getTickAtSqrtRatio(sqrtStart));
        tickLower = TickMath.minUsableTick(TICK_SPACING);
        liquidity = LiquidityAmounts.getLiquidityForAmount1(
            TickMath.getSqrtRatioAtTick(tickLower), TickMath.getSqrtRatioAtTick(tickUpper), SUPPLY
        );
    }

    /// @notice The normal rate for a .ai rate: always 3 points higher.
    function normalRate(uint16 aiBps) public pure returns (uint16) {
        return aiBps + NORMAL_SURCHARGE_BPS;
    }

    function _validate(CreateParams calldata p) private pure {
        if (p.buyTaxBps > MAX_TAX_BPS || p.sellTaxBps > MAX_TAX_BPS) revert InvalidTax();
        if (p.buyTaxBps != normalRate(p.agentBuyTaxBps) || p.sellTaxBps != normalRate(p.agentSellTaxBps)) revert InvalidTax();
        uint256 w = uint256(p.wFounder) + p.wHolder + p.wBurn + p.wLiquidity;
        bool taxed = p.buyTaxBps > 0 || p.sellTaxBps > 0;
        if (taxed ? w != 100 : w != 0) revert InvalidWeights();
        if (p.minShare < MIN_SHARE_FLOOR) revert InvalidMinShare();
        if (p.aiOnlySeconds < MIN_AI_ONLY || p.aiOnlySeconds > MAX_AI_ONLY) revert InvalidAiOnly();
        if (p.holdCapSeconds < p.aiOnlySeconds || p.holdCapSeconds > MAX_HOLD_CAP) revert InvalidHoldCap();
        bool permanent = p.taxSeconds == PERMANENT;
        if (!permanent && (p.taxSeconds < MIN_TAX_PERIOD || p.taxSeconds > MAX_TAX_PERIOD)) revert InvalidTaxPeriod();
        if (bytes(p.meta).length > MAX_META_BYTES) revert InvalidMeta();
    }

    function _floor(int24 tick) private pure returns (int24) {
        int24 r = tick / TICK_SPACING;
        if (tick < 0 && tick % TICK_SPACING != 0) r--;
        return r * TICK_SPACING;
    }

}
