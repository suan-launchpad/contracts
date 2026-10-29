// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {Currency} from "infinity-core/src/types/Currency.sol";
import {IHooks} from "infinity-core/src/interfaces/IHooks.sol";
import {IVault} from "infinity-core/src/interfaces/IVault.sol";
import {IPoolManager} from "infinity-core/src/interfaces/IPoolManager.sol";
import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {LPFeeLibrary} from "infinity-core/src/libraries/LPFeeLibrary.sol";
import {TickMath} from "infinity-core/src/pool-cl/libraries/TickMath.sol";
import {FullMath} from "infinity-core/src/pool-cl/libraries/FullMath.sol";
import {LiquidityAmounts} from "infinity-periphery/src/pool-cl/libraries/LiquidityAmounts.sol";
import {FixedPointMathLib} from "solmate/src/utils/FixedPointMathLib.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {StockToken} from "./StockToken.sol";
import {StockCurveHook} from "./StockCurveHook.sol";
import {StockTokenDeployer} from "./StockTokenDeployer.sol";
import {PERMANENT} from "./interfaces/IAgentLaunch.sol";

/// @title StockLaunchFactory
/// @notice Stock memes: anyone launches a token paired with an allowlisted bStock in one hooked PancakeSwap Infinity
///         pool holding the whole supply as a locked single-sided position, plus an optional creator presale paid in
///         the bStock, all in one transaction. Same rules as AgentLaunchFactory; the launch fee is still paid in BNB,
///         straight to SuanBuyBurn.
contract StockLaunchFactory is Ownable2Step {
    using SafeERC20 for IERC20;

    uint256 public constant SUPPLY = 1_000_000_000 ether;
    uint256 public constant MIN_SHARE_FLOOR = 10_000 ether;
    uint16 public constant MAX_TAX_BPS = 1_000;
    /// @notice Wallets without a .ai Agent ID always pay this much more tax than .ai wallets, during the tax period.
    uint16 public constant NORMAL_SURCHARGE_BPS = 300;
    uint64 public constant MIN_AI_ONLY = 2 minutes;
    uint64 public constant MAX_AI_ONLY = 30 minutes;
    uint64 public constant MAX_HOLD_CAP = 1 days;
    uint64 public constant MIN_TAX_PERIOD = 15 days;
    uint64 public constant MAX_TAX_PERIOD = 365 days;
    uint256 public constant MAX_META_BYTES = 128;
    int24 public constant TICK_SPACING = 10;

    IVault public immutable vault;
    ICLPoolManager public immutable poolManager;
    address public immutable agentId;
    address public immutable altPoolManager;
    StockCurveHook public immutable hook;
    StockTokenDeployer public immutable tokenDeployer;
    /// @notice Receives the BNB launch fee (the existing SuanBuyBurn, which buys and burns $SUAN with it).
    address public immutable suanBuyBurn;
    /// @notice One-time BNB fee per launch (`msg.value` must be exactly this).
    uint256 public immutable launchFee;
    /// @notice Whether anyone may create. Deployed closed: only the owner (the platform) launches until it opens.
    bool public launchesOpen;

    /// @notice Allowlisted bases: bStock => market cap at the launch price, in raw bStock units (the "start amount").
    ///         0 = not allowed for new launches. Existing launches keep their price and keep trading either way.
    mapping(address => uint256) public startAmountOf;

    struct CreateParams {
        address base; // allowlisted bStock
        uint256 presaleAmount; // bStock the creator spends on the presale (fee-inclusive; approve this factory first)
        string name;
        string symbol;
        string meta;
        address founder; // zero = creator
        uint16 buyTaxBps; // normal rate: always the .ai rate + 3 points (`normalRate`)
        uint16 sellTaxBps;
        uint16 agentBuyTaxBps;
        uint16 agentSellTaxBps;
        uint8 wFounder;
        uint8 wHolder;
        uint8 wBurn;
        uint8 wLiquidity;
        uint256 minShare;
        bool agentOnlyRewards;
        bool antiSniper;
        uint64 aiOnlySeconds;
        uint64 holdCapSeconds;
        uint64 taxSeconds;
    }

    event LaunchesOpened(bool open);
    event BaseSet(address indexed base, uint256 startAmount);
    event TokenLaunched(
        address indexed token,
        address indexed creator,
        address indexed base,
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
    error InvalidBase();
    error InvalidStartAmount();
    error BaseNotAllowed(address base);
    error LaunchFeeRequired(uint256 fee);
    error LaunchesClosed();
    error LaunchFeeTransferFailed();

    constructor(
        IVault vault_,
        ICLPoolManager poolManager_,
        address agentId_,
        address altPoolManager_,
        address treasury,
        address feeSink,
        address suanBuyBurn_,
        address[] memory trustedRouters,
        uint256 launchFee_
    ) Ownable(msg.sender) {
        vault = vault_;
        poolManager = poolManager_;
        agentId = agentId_;
        altPoolManager = altPoolManager_;
        suanBuyBurn = suanBuyBurn_;
        launchFee = launchFee_;
        hook = new StockCurveHook(vault_, poolManager_, agentId_, address(this), treasury, feeSink, trustedRouters);
        tokenDeployer = new StockTokenDeployer();
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

    /// @notice Allow a bStock for new launches, or change its start amount for new launches (0 removes it). Never
    ///         affects existing launches: their position is fixed at launch.
    /// @param startAmount market cap at the launch price in raw bStock units (18 decimals; e.g. 14.7e18 NVDAB ≈ $3.1K)
    function setBase(address base, uint256 startAmount) external onlyOwner {
        if (base == address(0) || hook.baseOf(base) != address(0)) revert InvalidBase();
        if (startAmount != 0) {
            // must give a valid position in both orientations
            position(startAmount, false);
            position(startAmount, true);
        }
        startAmountOf[base] = startAmount;
        emit BaseSet(base, startAmount);
    }

    /// @param p launch parameters; `msg.value` is exactly `launchFee`; `p.presaleAmount` of `p.base` is pulled from the
    ///          creator (the tokens it buys must stay within 3% of the supply)
    function create(CreateParams calldata p) external payable returns (StockToken) {
        if (!launchesOpen && msg.sender != owner()) revert LaunchesClosed();
        return _create(p);
    }

    /// @notice The platform's first launch and the opening of creation to everyone, in one transaction.
    function createAndOpen(CreateParams calldata p) external payable onlyOwner returns (StockToken token) {
        token = _create(p);
        launchesOpen = true;
        emit LaunchesOpened(true);
    }

    function _create(CreateParams calldata p) private returns (StockToken token) {
        if (msg.value != launchFee) revert LaunchFeeRequired(launchFee);
        uint256 startAmount = startAmountOf[p.base];
        if (startAmount == 0) revert BaseNotAllowed(p.base);
        _validate(p);

        token = _deployToken(p);
        (PoolKey memory key, uint160 startPrice) = _register(p, token, startAmount);
        poolManager.initialize(key, startPrice);
        hook.seed(address(token));
        if (launchFee > 0) {
            (bool ok,) = suanBuyBurn.call{value: launchFee}("");
            if (!ok) revert LaunchFeeTransferFailed();
        }
        if (p.presaleAmount > 0) {
            IERC20(p.base).safeTransferFrom(msg.sender, address(hook), p.presaleAmount);
            hook.presale(address(token), msg.sender, p.presaleAmount);
        }

        emit TokenLaunched(address(token), msg.sender, p.base, address(token.rewards()), p.name, p.symbol, p.meta);
    }

    function _deployToken(CreateParams calldata p) private returns (StockToken) {
        return tokenDeployer.deploy(
            StockToken.Config({
                name: p.name,
                symbol: p.symbol,
                meta: p.meta,
                hook: address(hook),
                creator: msg.sender,
                vault: address(vault),
                altPoolManager: altPoolManager,
                agentId: agentId,
                base: p.base,
                aiOnlySeconds: p.aiOnlySeconds,
                holdCapSeconds: p.holdCapSeconds,
                taxSeconds: p.taxSeconds,
                minShare: p.minShare,
                agentOnlyRewards: p.agentOnlyRewards
            })
        );
    }

    function _register(CreateParams calldata p, StockToken token, uint256 startAmount)
        private
        returns (PoolKey memory key, uint160 startPrice)
    {
        bool memeIs0 = address(token) < p.base;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        (tickLower, tickUpper, liquidity, startPrice) = position(startAmount, memeIs0);
        (address c0, address c1) = memeIs0 ? (address(token), p.base) : (p.base, address(token));
        key = PoolKey({
            currency0: Currency.wrap(c0),
            currency1: Currency.wrap(c1),
            hooks: IHooks(address(hook)),
            poolManager: IPoolManager(address(poolManager)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            parameters: bytes32(uint256(hook.getHooksRegistrationBitmap()) | (uint256(uint24(TICK_SPACING)) << 16))
        });
        StockCurveHook.LaunchConfig memory c;
        c.token = address(token);
        c.base = p.base;
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
    }

    /// @notice The single-sided position holding the whole supply, for a market cap of `startAmount` bStock at the
    ///         launch price. Pools sort currencies by address, so the price is meme per bStock when the bStock is
    ///         currency0 and bStock per meme when the meme is: either way trading starts at the launch price and the
    ///         position reaches to the end of the usable tick range on the side buys move the price to, so there is
    ///         liquidity at every higher meme price. Same shape as a constant-product curve with `startAmount` of
    ///         virtual bStock. The start tick is rounded to the tick spacing toward a higher market cap (at most
    ///         0.1% off `startAmount`).
    ///         `startPrice` is the pool's initial sqrtPriceX96.
    function position(uint256 startAmount, bool memeIs0)
        public
        pure
        returns (int24 tickLower, int24 tickUpper, uint128 liquidity, uint160 startPrice)
    {
        if (startAmount == 0) revert InvalidStartAmount();
        if (memeIs0) {
            // price = bStock per meme = startAmount / SUPPLY; buys move it up
            uint160 sqrtStart = uint160(FixedPointMathLib.sqrt(FullMath.mulDiv(startAmount, 1 << 192, SUPPLY)));
            tickLower = _ceil(TickMath.getTickAtSqrtRatio(sqrtStart));
            tickUpper = TickMath.maxUsableTick(TICK_SPACING);
            if (tickLower >= tickUpper) revert InvalidStartAmount();
            startPrice = TickMath.getSqrtRatioAtTick(tickLower);
            liquidity = LiquidityAmounts.getLiquidityForAmount0(startPrice, TickMath.getSqrtRatioAtTick(tickUpper), SUPPLY);
        } else {
            // price = meme per bStock = SUPPLY / startAmount; buys move it down
            uint160 sqrtStart = uint160(FixedPointMathLib.sqrt(FullMath.mulDiv(SUPPLY, 1 << 192, startAmount)));
            tickUpper = _floor(TickMath.getTickAtSqrtRatio(sqrtStart));
            tickLower = TickMath.minUsableTick(TICK_SPACING);
            if (tickLower >= tickUpper) revert InvalidStartAmount();
            startPrice = TickMath.getSqrtRatioAtTick(tickUpper);
            liquidity = LiquidityAmounts.getLiquidityForAmount1(TickMath.getSqrtRatioAtTick(tickLower), startPrice, SUPPLY);
        }
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

    function _ceil(int24 tick) private pure returns (int24) {
        int24 r = _floor(tick);
        return r == tick ? r : r + TICK_SPACING;
    }
}
