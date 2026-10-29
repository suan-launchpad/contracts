// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, Vm} from "forge-std/Test.sol";
import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {Currency} from "infinity-core/src/types/Currency.sol";
import {PoolIdLibrary} from "infinity-core/src/types/PoolId.sol";
import {IVault} from "infinity-core/src/interfaces/IVault.sol";
import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {TickMath} from "infinity-core/src/pool-cl/libraries/TickMath.sol";
import {ICLRouterBase} from "infinity-periphery/src/pool-cl/interfaces/ICLRouterBase.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {StockLaunchFactory} from "../src/StockLaunchFactory.sol";
import {StockCurveHook} from "../src/StockCurveHook.sol";
import {StockToken} from "../src/StockToken.sol";
import {StockRouter} from "../src/StockRouter.sol";
import {StockFeeSink} from "../src/StockFeeSink.sol";
import {StockHolderRewards} from "../src/StockHolderRewards.sol";
import {KnownPools} from "../src/libraries/KnownPools.sol";
import {LiquidityAdder} from "./AgentLaunch.t.sol";

interface IAgentIdAdminS {
    function adminRegister(string calldata handle, address to) external;
    function owner() external view returns (address);
    function balanceOf(address) external view returns (uint256);
}

interface IUniversalRouterS {
    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline) external payable;
}

interface IPermit2S {
    function approve(address token, address spender, uint160 amount, uint48 expiration) external;
}

interface IPairFactoryS {
    function createPair(address a, address b) external returns (address);
}

interface IV3FactoryS {
    function createPool(address a, address b, uint24 fee) external returns (address);
}

interface IPauseManagerS {
    function isTokenPaused(address token) external view returns (bool);
}

interface IComplianceS {
    function checkIsCompliant(address token, address user) external view;
}

interface ISuanBuyBurnS {
    function keeper() external view returns (address);
    function buyAndBurn(uint256 maxBnb, uint256 minSuanBurned) external returns (uint256);
}

/// @notice Shared setup of the stock-meme fork tests: real PancakeSwap Infinity Vault / CLPoolManager, real bStocks
///         (NVDAB, SPCXB), real PancakeSwap V3 pools, the real SPACE ID Agent ID and the real SuanBuyBurn. Each concrete
///         suite picks a base and the pool orientation (whether the meme sorts before the bStock); the token deployer's
///         nonce is moved so that every launch of the suite gets that orientation.
abstract contract StockLaunchBase is Test {
    using PoolIdLibrary for PoolKey;

    IVault constant VAULT = IVault(0x238a358808379702088667322f80aC48bAd5e6c4);
    ICLPoolManager constant CLPM = ICLPoolManager(0xa0FfB9c1CE1Fe56963B0321B32E7A0302114058b);
    address constant AGENT_ID = 0x60B9262456dE011F7d15a54CdD8c48bAaa8B022F;
    address constant UNI_V4_PM = 0x28e2Ea090877bF75740558f6BFB36A5ffeE9e9dF;
    address constant PCS_UR = 0xd9C500DfF816a1Da21A48A732d3498Bf09dc9AEB;
    address constant PERMIT2 = 0x31c2F6fcFf4F8759b3Bd5Bf0e1084A055615c768;
    address constant V3_ROUTER = 0x1b81D678ffb9C0263b24A97847620C99d213eB14;
    address constant V3_QUOTER = 0xB048Bbc1Ee6b733FFfCFb9e9CeF7375518e25997;
    address constant PCS_V2_FACTORY = 0xcA143Ce32Fe78f1f7019d7d551a6402fC5350c73;
    address constant PCS_V3_FACTORY = 0x0BFbCF9fa4f9C56B0F40a671Ad40E0805A091865;
    address constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address constant USDT = 0x55d398326f99059fF775485246999027B3197955;
    address constant NVDAB = 0x02Fca66C1D1aFB4E2A7884261eB00F63598a7436;
    address constant SPCXB = 0xbe9D156892E55e7154BcD3cB0FEA677F9D3103E1;
    address constant PAUSE_MANAGER = 0x9fc74Be63f3589485B2423984a7a0557e0CF700a;
    address constant COMPLIANCE = 0x53dBa7AaBDe774787A1F57236B235567dA8e14F4;
    address payable constant SUAN_BUY_BURN = payable(0xF611041e441CD2037d415cB368d8cB45F31E134A);
    address constant SUAN = 0xC561DC47b9c1C036E77EcffDDE66B8f451847777;
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;

    /// @dev ≈ $3.1K at the 2026-10-29 prices (NVDAB ≈ $213, SPCXB ≈ $143), i.e. 4.2 BNB at ≈ $749
    uint256 constant NVDAB_START = 14.7 ether;
    uint256 constant SPCXB_START = 22 ether;
    uint256 constant BNB_START = 4.2 ether;

    uint64 constant AI_ONLY = 2 minutes;
    uint64 constant HOLD_CAP_WINDOW = 1 hours;
    uint64 constant TAX_PERIOD = 15 days;

    StockLaunchFactory factory;
    StockCurveHook hook;
    StockRouter router;
    StockFeeSink sink;
    StockToken token;
    PoolKey key;
    address base;
    uint256 start;
    address treasury = makeAddr("treasury");
    address creator = makeAddr("creator");
    address outsider = makeAddr("outsider");
    address keeper = makeAddr("keeper");
    uint256 agentCount;

    function _base() internal pure virtual returns (address);
    function _memeIs0() internal pure virtual returns (bool);

    function setUp() public virtual {
        vm.createSelectFork(vm.envOr("BSC_RPC_URL", string("https://bsc-dataseed.bnbchain.org")));
        // label-derived addresses carry EIP-7702 sweeper delegations on BSC mainnet; make them plain accounts
        vm.etch(treasury, "");
        vm.etch(creator, "");
        vm.etch(outsider, "");
        vm.etch(keeper, "");
        router = new StockRouter(VAULT, CLPM, V3_ROUTER, WBNB);
        sink = new StockFeeSink(WBNB, SUAN_BUY_BURN, V3_ROUTER, keeper, address(this));
        factory = _newFactory(0);
        hook = factory.hook();
        factory.setLaunchesOpen(true);
        base = _base();
        start = factory.startAmountOf(base);
        vm.deal(creator, 10 ether);
        vm.deal(outsider, 10 ether);
        token = _launch(_b(0.1 ether));
        key = hook.poolKeyOf(address(token));
        vm.roll(block.number + 10); // past the anti-sniper ladder; still inside the 2-minute .ai window
    }

    // ------------------------------------------------------------------
    // helpers
    // ------------------------------------------------------------------

    function _newFactory(uint256 fee) internal returns (StockLaunchFactory f) {
        address[] memory routers = new address[](2);
        routers[0] = address(router);
        routers[1] = PCS_UR;
        f = new StockLaunchFactory(VAULT, CLPM, AGENT_ID, UNI_V4_PM, treasury, address(sink), SUAN_BUY_BURN, routers, fee);
        f.setBase(NVDAB, NVDAB_START);
        f.setBase(SPCXB, SPCXB_START);
    }

    /// @dev The same share of the start market cap as `bnb` is of a BNB launch's 4.2 BNB.
    function _b(uint256 bnb) internal view returns (uint256) {
        return bnb * start / BNB_START / 10_000 * 10_000; // whole bps, so fee parts add up exactly
    }

    function _params() internal view returns (StockLaunchFactory.CreateParams memory p) {
        p.base = base;
        p.name = "Stock Meme";
        p.symbol = "SMM";
        p.buyTaxBps = 400;
        p.sellTaxBps = 400;
        p.agentBuyTaxBps = 100;
        p.agentSellTaxBps = 100;
        p.wFounder = 40;
        p.wHolder = 30;
        p.wBurn = 20;
        p.wLiquidity = 10;
        p.minShare = 10_000 ether;
        p.antiSniper = true;
        p.aiOnlySeconds = AI_ONLY;
        p.holdCapSeconds = HOLD_CAP_WINDOW;
        p.taxSeconds = TAX_PERIOD;
    }

    /// @dev Move the token deployer's nonce so its next token sorts before (`memeIs0`) or after `b`.
    function _orient(StockLaunchFactory f, address b, bool memeIs0) internal {
        address d = address(f.tokenDeployer());
        uint64 n = vm.getNonce(d);
        while ((vm.computeCreateAddress(d, n) < b) != memeIs0) n++;
        vm.setNonce(d, n);
    }

    function _fund(address who, uint256 amount) internal {
        deal(base, who, IERC20(base).balanceOf(who) + amount);
    }

    function _createWith(StockLaunchFactory f, StockLaunchFactory.CreateParams memory p, address who)
        internal
        returns (StockToken t)
    {
        if (p.base == base) _orient(f, p.base, _memeIs0());
        if (p.presaleAmount > 0) {
            deal(p.base, who, IERC20(p.base).balanceOf(who) + p.presaleAmount);
            vm.prank(who);
            IERC20(p.base).approve(address(f), p.presaleAmount);
        }
        uint256 fee = f.launchFee();
        vm.prank(who, who);
        t = f.create{value: fee}(p);
    }

    function _launch(uint256 presale) internal returns (StockToken) {
        StockLaunchFactory.CreateParams memory p = _params();
        p.presaleAmount = presale;
        return _createWith(factory, p, creator);
    }

    function _useToken(StockLaunchFactory.CreateParams memory p, uint256 presale) internal {
        p.presaleAmount = presale;
        token = _createWith(factory, p, creator);
        key = hook.poolKeyOf(address(token));
        vm.roll(block.number + 10);
    }

    function _agent() internal returns (address a) {
        agentCount++;
        string memory handle = string.concat("zqxstock", vm.toString(agentCount));
        a = makeAddr(handle);
        vm.etch(a, "");
        vm.prank(IAgentIdAdminS(AGENT_ID).owner());
        IAgentIdAdminS(AGENT_ID).adminRegister(handle, a);
        vm.deal(a, 100 ether);
    }

    function _buy(address who, uint256 amount) internal returns (uint256) {
        return _buyTo(who, amount, who);
    }

    function _buyTo(address who, uint256 amount, address recipient) internal returns (uint256 out) {
        _fund(who, amount);
        vm.startPrank(who, who);
        IERC20(base).approve(address(router), amount);
        out = router.buy(key, amount, 0, recipient);
        vm.stopPrank();
    }

    function _sell(address who, uint256 amount) internal returns (uint256 out) {
        vm.startPrank(who, who);
        token.approve(address(router), amount);
        out = router.sell(key, amount, 0, who);
        vm.stopPrank();
    }

    function _afterAiWindow() internal {
        vm.warp(token.aiOnlyUntil());
    }

    function _afterHoldCap() internal {
        vm.warp(token.holdCapUntil());
    }

    /// @dev bStock withheld as fees: the hook's Vault claims plus the claims minted straight to HolderRewards.
    function _taken() internal view returns (uint256) {
        Currency c = Currency.wrap(base);
        return VAULT.balanceOf(address(hook), c) + VAULT.balanceOf(address(token.rewards()), c);
    }

    function _buyPath() internal view returns (bytes memory) {
        return abi.encodePacked(WBNB, uint24(2500), base);
    }

    function _sellPath() internal view returns (bytes memory) {
        return abi.encodePacked(base, uint24(2500), WBNB);
    }

    /// @dev Single-pool exact-input swap through the real PancakeSwap Universal Router: INFI_SWAP with
    ///      CL_SWAP_EXACT_IN_SINGLE, SETTLE_ALL, TAKE_ALL (swap first, pay after).
    function _urSwap(address who, bool isBuy, uint256 amountIn, uint256 minOut) internal {
        Currency baseC = Currency.wrap(base);
        Currency memeC = Currency.wrap(address(token));
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(
            ICLRouterBase.CLSwapExactInputSingleParams({
                poolKey: key,
                zeroForOne: isBuy != _memeIs0(),
                amountIn: uint128(amountIn),
                amountOutMinimum: uint128(minOut),
                hookData: ""
            })
        );
        params[1] = abi.encode(isBuy ? baseC : memeC, amountIn);
        params[2] = abi.encode(isBuy ? memeC : baseC, minOut);
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(abi.encodePacked(uint8(0x06), uint8(0x0c), uint8(0x0f)), params);
        address paid = isBuy ? base : address(token);
        vm.startPrank(who, who);
        IERC20(paid).approve(PERMIT2, type(uint256).max);
        IPermit2S(PERMIT2).approve(paid, PCS_UR, type(uint160).max, uint48(block.timestamp + 1 days));
        IUniversalRouterS(PCS_UR).execute(hex"10", inputs, block.timestamp);
        vm.stopPrank();
    }

    function _swappedOf(address t, address trader)
        internal
        returns (bool isBuy, uint256 baseAmount, uint256 tokens, uint160 price)
    {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool found;
        for (uint256 i; i < logs.length; ++i) {
            Vm.Log memory l = logs[i];
            if (l.emitter != address(hook) || l.topics[0] != StockCurveHook.Swapped.selector) continue;
            if (address(uint160(uint256(l.topics[1]))) != t || address(uint160(uint256(l.topics[2]))) != trader) continue;
            (isBuy, baseAmount, tokens, price) = abi.decode(l.data, (bool, uint256, uint256, uint160));
            found = true;
        }
        assertTrue(found, "Swapped emitted");
    }

    function _sqrtNow() internal view returns (uint160 s) {
        (s,,,) = CLPM.getSlot0(key.toId());
    }

    /// @dev meme tokens per bStock unit at a pool price, whichever orientation
    function _memePerBase(uint160 sqrtP) internal pure returns (uint256) {
        uint256 p = uint256(sqrtP) * uint256(sqrtP);
        return _memeIs0() ? (uint256(1) << 192) / p : p >> 192;
    }
}

/// @notice The stock-meme rules, mirroring AgentLaunch.t.sol, run once per base / orientation below.
abstract contract StockLaunchTests is StockLaunchBase {
    using PoolIdLibrary for PoolKey;

    // ------------------------------------------------------------------
    // creation
    // ------------------------------------------------------------------

    function test_create_orientationAndWholeSupply() public view {
        StockCurveHook.LaunchView memory v = hook.launchInfo(address(token));
        assertEq(v.memeIsCurrency0, _memeIs0(), "suite orientation");
        assertEq(v.base, base);
        assertEq(Currency.unwrap(_memeIs0() ? key.currency0 : key.currency1), address(token));
        assertEq(Currency.unwrap(_memeIs0() ? key.currency1 : key.currency0), base);
        (int24 lo, int24 hi, uint128 liq,) = factory.position(start, _memeIs0());
        if (_memeIs0()) assertEq(hi, TickMath.maxUsableTick(10), "reaches every higher meme price");
        else assertEq(lo, TickMath.minUsableTick(10), "reaches every higher meme price");
        assertEq(CLPM.getLiquidity(key.toId()), liq, "the launch position is the only liquidity");
        assertEq(token.totalSupply(), 1_000_000_000 ether);
        assertEq(token.balanceOf(address(hook)), 0, "the hook keeps no tokens");
        assertEq(IERC20(base).balanceOf(address(hook)), 0, "the hook keeps no bStock as ERC20");
    }

    function test_create_startPriceIsTheStartAmount() public {
        StockToken t = _launch(0);
        (uint160 sqrtP,,,) = CLPM.getSlot0(hook.poolKeyOf(address(t)).toId());
        // market cap at the start price = start amount: SUPPLY / start meme per bStock
        assertApproxEqRel(_memePerBase(sqrtP), 1_000_000_000 ether / start, 0.002e18);
        assertLe(_memePerBase(sqrtP), 1_000_000_000 ether / start, "rounded toward a higher market cap");
    }

    function test_create_bothOrientationsGiveTheSameStartPrice() public view {
        (,,, uint160 a) = factory.position(start, false);
        (,,, uint160 b) = factory.position(start, true);
        uint256 memeA = (uint256(a) * uint256(a)) >> 192;
        uint256 memeB = (uint256(1) << 192) / (uint256(b) * uint256(b));
        assertApproxEqRel(memeA, memeB, 0.002e18);
    }

    function test_create_timesAreSetFromLaunch() public view {
        assertEq(token.aiOnlyUntil(), token.launchTime() + AI_ONLY);
        assertEq(token.holdCapUntil(), token.launchTime() + HOLD_CAP_WINDOW);
        assertEq(token.taxEnd(), token.launchTime() + TAX_PERIOD);
        StockCurveHook.LaunchView memory v = hook.launchInfo(address(token));
        assertTrue(v.exists);
        assertEq(v.aiOnlyUntil, token.aiOnlyUntil());
        assertEq(v.buyTaxNowBps, 400);
        assertEq(v.wFounder, 40);
        assertEq(token.base(), base);
        assertEq(token.rewards().asset(), base, "rewards paid in the bStock");
        assertFalse(hook.launchInfo(address(0xBEEF)).exists);
    }

    function test_create_validates() public {
        StockLaunchFactory.CreateParams memory p = _params();
        p.aiOnlySeconds = 1 minutes;
        vm.prank(creator, creator);
        vm.expectRevert(StockLaunchFactory.InvalidAiOnly.selector);
        factory.create(p);

        p = _params();
        p.buyTaxBps = 300;
        vm.prank(creator, creator);
        vm.expectRevert(StockLaunchFactory.InvalidTax.selector);
        factory.create(p);

        p = _params();
        p.meta = string(new bytes(129));
        vm.prank(creator, creator);
        vm.expectRevert(StockLaunchFactory.InvalidMeta.selector);
        factory.create(p);
    }

    function test_create_onlyAllowlistedBases() public {
        StockLaunchFactory.CreateParams memory p = _params();
        p.base = USDT;
        vm.prank(creator, creator);
        vm.expectRevert(abi.encodeWithSelector(StockLaunchFactory.BaseNotAllowed.selector, USDT));
        factory.create(p);
    }

    function test_base_removingOrRepricingLeavesExistingLaunches() public {
        uint160 before = _sqrtNow();
        factory.setBase(base, start * 2);
        assertEq(factory.startAmountOf(base), start * 2);
        assertEq(_sqrtNow(), before, "existing pool untouched");
        StockToken t2 = _launch(0);
        (uint160 sqrt2,,,) = CLPM.getSlot0(hook.poolKeyOf(address(t2)).toId());
        assertApproxEqRel(_memePerBase(sqrt2), 1_000_000_000 ether / (start * 2), 0.002e18, "new launches use the new start");

        factory.setBase(base, 0);
        vm.prank(creator, creator);
        vm.expectRevert(abi.encodeWithSelector(StockLaunchFactory.BaseNotAllowed.selector, base));
        factory.create(_params());
        address a = _agent();
        assertGt(_buy(a, _b(0.01 ether)), 0, "existing launches keep trading");
    }

    function test_base_setBaseValidates() public {
        vm.prank(outsider);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", outsider));
        factory.setBase(USDT, 1 ether);
        vm.expectRevert(StockLaunchFactory.InvalidBase.selector);
        factory.setBase(address(0), 1 ether);
        vm.expectRevert(StockLaunchFactory.InvalidBase.selector);
        factory.setBase(address(token), 1 ether); // a launch token cannot be a base
        vm.expectRevert(); // out of the usable price range
        factory.setBase(USDT, 1);
        vm.expectEmit(address(factory));
        emit StockLaunchFactory.BaseSet(USDT, 3_000 ether);
        factory.setBase(USDT, 3_000 ether);
    }

    function test_create_sendsLaunchFeeInBnbToSuanBuyBurn() public {
        StockLaunchFactory paid = _newFactory(0.005 ether);
        paid.setLaunchesOpen(true);
        uint256 before = SUAN_BUY_BURN.balance;
        _createWith(paid, _params(), creator);
        assertEq(SUAN_BUY_BURN.balance - before, 0.005 ether, "launch fee straight to SuanBuyBurn");

        vm.prank(creator, creator);
        vm.expectRevert(abi.encodeWithSelector(StockLaunchFactory.LaunchFeeRequired.selector, 0.005 ether));
        paid.create{value: 0.004 ether}(_params());
        vm.prank(creator, creator);
        vm.expectRevert(abi.encodeWithSelector(StockLaunchFactory.LaunchFeeRequired.selector, 0.005 ether));
        paid.create{value: 0.006 ether}(_params());
    }

    function test_lp_thirdPartyCannotAddLiquidity() public {
        LiquidityAdder adder = new LiquidityAdder(VAULT, CLPM);
        vm.expectRevert();
        adder.add(key);
    }

    function test_trade_bigBuysNeverRunOutOfLiquidity() public {
        _afterHoldCap();
        uint256 amount = start * 100;
        uint256 got = _buy(outsider, amount);
        assertGt(got, 0);
        uint256 back = _sell(outsider, got);
        assertGt(back, amount * 90 / 100, "the same pool buys it back: only fees and price impact are lost");
    }

    // ------------------------------------------------------------------
    // creator presale, paid in the bStock
    // ------------------------------------------------------------------

    function test_presale_exemptFromGateAndCap() public view {
        assertGt(token.balanceOf(creator), token.HOLD_CAP(), "creator presale is exempt from the 1% cap");
        assertEq(IAgentIdAdminS(AGENT_ID).balanceOf(creator), 0, "creator has no Agent ID");
        assertEq(IERC20(base).balanceOf(address(hook)), 0, "presale bStock fully used or refunded");
    }

    function test_presale_overThreePercentReverts() public {
        StockLaunchFactory.CreateParams memory p = _params();
        p.presaleAmount = _b(0.2 ether);
        _orient(factory, base, _memeIs0());
        deal(base, creator, p.presaleAmount);
        vm.prank(creator);
        IERC20(base).approve(address(factory), p.presaleAmount);
        vm.prank(creator, creator);
        vm.expectRevert(abi.encodeWithSelector(StockCurveHook.PresaleCap.selector, 30_000_000 ether));
        factory.create(p);
    }

    function test_presale_paysTheCreatorsRateInBStock() public {
        vm.recordLogs();
        uint256 amount = _b(0.1 ether);
        StockToken t = _launch(amount);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool found;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(hook) || logs[i].topics[0] != StockCurveHook.FeeTaken.selector) continue;
            if (address(uint160(uint256(logs[i].topics[1]))) != address(t)) continue;
            (bool isBuy, uint256 b, uint256 tax, uint256 anti) = abi.decode(logs[i].data, (bool, uint256, uint256, uint256));
            assertTrue(isBuy);
            assertEq(b, amount * 100 / 10_000, "base fee 1%");
            assertEq(tax, amount * 400 / 10_000, "creator has no .ai: normal 4%");
            assertEq(anti, 0);
            found = true;
        }
        assertTrue(found);
    }

    // ------------------------------------------------------------------
    // .ai window
    // ------------------------------------------------------------------

    function test_aiWindow_outsiderCannotBuy() public {
        uint256 amount = _b(0.01 ether);
        _fund(outsider, amount);
        vm.startPrank(outsider, outsider);
        IERC20(base).approve(address(router), amount);
        vm.expectRevert();
        router.buy(key, amount, 0, outsider);
        vm.stopPrank();
    }

    function test_aiWindow_recipientMustBeAgent() public {
        address a = _agent();
        uint256 amount = _b(0.01 ether);
        _fund(a, amount);
        vm.startPrank(a, a);
        IERC20(base).approve(address(router), amount);
        vm.expectRevert();
        router.buy(key, amount, 0, outsider);
        vm.stopPrank();
    }

    function test_aiWindow_walletTransfersLocked() public {
        address a = _agent();
        address b = _agent();
        _buy(a, _b(0.01 ether));
        vm.prank(a, a);
        vm.expectRevert(StockToken.TransferLocked.selector);
        token.transfer(b, 1 ether);
    }

    function test_aiWindow_creatorCanSellWithoutAgentId() public {
        assertGt(_sell(creator, token.balanceOf(creator) / 10), 0);
    }

    function test_aiWindow_endsThenAnyoneBuys() public {
        _afterAiWindow();
        assertGt(_buy(outsider, _b(0.01 ether)), 0);
        address friend = makeAddr("friend");
        vm.prank(outsider, outsider);
        token.transfer(friend, 1 ether);
        assertEq(token.balanceOf(friend), 1 ether);
    }

    function test_aiWindow_universalRouterBuyStillGated() public {
        _fund(outsider, _b(0.01 ether));
        vm.expectRevert();
        this.urSwapExternal(outsider, true, _b(0.01 ether), 1);
    }

    function urSwapExternal(address who, bool isBuy, uint256 amountIn, uint256 minOut) external {
        _urSwap(who, isBuy, amountIn, minOut);
    }

    // ------------------------------------------------------------------
    // 1% hold cap
    // ------------------------------------------------------------------

    function test_holdCap_buyOverOnePercentReverts() public {
        address a = _agent();
        uint256 amount = _b(0.5 ether);
        _fund(a, amount);
        vm.startPrank(a, a);
        IERC20(base).approve(address(router), amount);
        vm.expectRevert();
        router.buy(key, amount, 0, a);
        vm.stopPrank();
    }

    function test_holdCap_transfersCountToo() public {
        _afterAiWindow();
        address a = _agent();
        address b = _agent();
        _buy(a, _b(0.03 ether));
        _buy(b, _b(0.03 ether));
        uint256 bal = token.balanceOf(a);
        vm.prank(a, a);
        vm.expectRevert(abi.encodeWithSelector(StockToken.HoldCap.selector, b));
        token.transfer(b, bal);
    }

    function test_holdCap_endsAfterItsWindow() public {
        _afterHoldCap();
        address a = _agent();
        assertGt(_buy(a, _b(1 ether)), token.HOLD_CAP());
    }

    // ------------------------------------------------------------------
    // fees, withheld in the bStock
    // ------------------------------------------------------------------

    function test_fees_agentBuySplit() public {
        address a = _agent();
        StockHolderRewards r = token.rewards();
        Currency c = Currency.wrap(base);
        uint256 rewardsBefore = VAULT.balanceOf(address(r), c);
        uint256 before = _taken();
        (uint256 t0, uint256 f0,, uint256 b0) = hook.owedOf(address(token));
        uint256 s0 = hook.suanOwedOf(address(token));
        uint256 amount = _b(0.03 ether);
        uint256 out = _buy(a, amount);
        assertEq(token.balanceOf(a), out);

        uint256 fee = amount * 100 / 10_000;
        uint256 tax = amount * 100 / 10_000; // .ai rate 1%
        assertEq(_taken() - before, fee + tax, "fee withheld in bStock");
        (uint256 t1, uint256 f1, uint256 h1, uint256 b1) = hook.owedOf(address(token));
        assertEq(f1 - f0, fee / 2 + tax * 40 / 100, "creator: half the base fee + 40% of the tax");
        assertEq(h1, 0, "holder bucket never waits");
        assertEq(VAULT.balanceOf(address(r), c) - rewardsBefore, tax * 30 / 100, "holders 30%, with the trade");
        assertEq(b1 - b0, tax * 20 / 100, "burn 20% -> buyback");
        assertEq(hook.suanOwedOf(address(token)) - s0, fee - fee / 2, "platform half -> $SUAN bucket");
        assertEq(t1 - t0, tax - tax * 40 / 100 - tax * 30 / 100 - tax * 20 / 100, "treasury: the liquidity share only");
        assertEq(
            VAULT.balanceOf(address(hook), c),
            t1 + f1 + b1 + hook.suanOwedOf(address(token)),
            "the hook's claims are exactly its buckets"
        );
    }

    function test_fees_outsiderPaysNormalRateAgentPaysAiRate() public {
        _afterAiWindow();
        uint256 amount = _b(0.02 ether);
        uint256 before = _taken();
        _buy(outsider, amount);
        assertEq(_taken() - before, amount * 500 / 10_000, "outsider: 1% + 4%");
        address a = _agent();
        before = _taken();
        _buy(a, amount);
        assertEq(_taken() - before, amount * 200 / 10_000, ".ai: 1% + 1%");
    }

    function test_fees_surchargeAlwaysBurnsNeverPaysTheCreator() public {
        StockLaunchFactory.CreateParams memory p = _params();
        p.wFounder = 100;
        p.wHolder = 0;
        p.wBurn = 0;
        p.wLiquidity = 0;
        _useToken(p, 0);
        _afterAiWindow();
        uint256 amount = _b(0.02 ether);
        (uint256 t0, uint256 f0,, uint256 b0) = hook.owedOf(address(token));
        _buy(outsider, amount);
        (uint256 t1, uint256 f1,, uint256 b1) = hook.owedOf(address(token));
        uint256 fee = amount * 100 / 10_000;
        assertEq(f1 - f0, fee / 2 + amount * 100 / 10_000, "creator: its 0.5% + the .ai-rate part only");
        assertEq(b1 - b0, amount * 300 / 10_000, "the 3% surcharge: all to the token's own buyback");
        assertEq(t1, t0);

        vm.warp(token.taxEnd());
        (,,, uint256 b2) = hook.owedOf(address(token));
        _buy(outsider, amount);
        (,,, uint256 b3) = hook.owedOf(address(token));
        assertEq(b3, b2, "no surcharge after the tax period");
    }

    function test_fees_sellFeeTakenFromBStockOut() public {
        address a = _agent();
        uint256 got = _buy(a, _b(0.03 ether));
        uint256 before = _taken();
        uint256 out = _sell(a, got / 2);
        uint256 fee = _taken() - before;
        assertGt(out, 0);
        assertEq(IERC20(base).balanceOf(a), out, "seller receives bStock");
        assertApproxEqAbs(fee, (out + fee) * 200 / 10_000, 2, "1% base + 1% .ai rate of gross bStock out");
    }

    function test_fees_afterTaxPeriodEveryonePaysTheAiRate() public {
        vm.warp(token.taxEnd());
        uint256 amount = _b(0.1 ether);
        uint256 before = _taken();
        _buy(outsider, amount);
        assertEq(_taken() - before, amount * 200 / 10_000);
        assertEq(hook.launchInfo(address(token)).buyTaxNowBps, 100);
    }

    function test_fees_platformHalfToFeeSinkInBStock() public {
        StockLaunchFactory.CreateParams memory p = _params();
        p.buyTaxBps = 300;
        p.sellTaxBps = 300;
        p.agentBuyTaxBps = 0;
        p.agentSellTaxBps = 0;
        _useToken(p, 0);
        _afterHoldCap();
        address a = _agent();
        uint256 amount = _b(0.1 ether);
        _buy(a, amount);
        uint256 owed = hook.suanOwedOf(address(token));
        assertEq(owed, amount * 50 / 10_000, "platform 0.5%");
        (, uint256 f,,) = hook.owedOf(address(token));
        assertEq(f, amount * 50 / 10_000, "creator 0.5%");

        uint256 sinkBefore = IERC20(base).balanceOf(address(sink));
        vm.expectEmit(address(hook));
        emit StockCurveHook.SuanDispatched(address(token), owed);
        hook.dispatch(address(token));
        assertEq(IERC20(base).balanceOf(address(sink)) - sinkBefore, owed, "dispatch pays the bStock to StockFeeSink");
        assertEq(hook.suanOwedOf(address(token)), 0);
    }

    function test_fees_dispatchPaysTreasuryInBStock() public {
        address a = _agent();
        _buy(a, _b(0.03 ether));
        (uint256 t,,,) = hook.owedOf(address(token));
        assertGt(t, 0);
        hook.dispatch(address(token));
        assertEq(IERC20(base).balanceOf(treasury), t);
        (uint256 t2,,,) = hook.owedOf(address(token));
        assertEq(t2, 0);
    }

    function test_fees_creatorCanSendItsShareToHolders() public {
        vm.prank(outsider);
        vm.expectRevert(StockCurveHook.NotCreator.selector);
        hook.setCreatorShareToHolders(address(token));

        vm.prank(creator);
        hook.setCreatorShareToHolders(address(token));
        assertTrue(hook.launchInfo(address(token)).creatorShareToHolders);

        address a = _agent();
        Currency c = Currency.wrap(base);
        (, uint256 f0,,) = hook.owedOf(address(token));
        uint256 r0 = VAULT.balanceOf(address(token.rewards()), c);
        uint256 amount = _b(0.02 ether);
        _buy(a, amount);
        (, uint256 f1,,) = hook.owedOf(address(token));
        uint256 tax = amount * 100 / 10_000;
        assertEq(f1 - f0, tax * 40 / 100, "creator keeps only its tax share");
        assertEq(VAULT.balanceOf(address(token.rewards()), c) - r0, amount * 50 / 10_000 + tax * 30 / 100);
    }

    function test_fees_antiSniperLadder() public {
        StockToken t2 = _launch(0);
        PoolKey memory k2 = hook.poolKeyOf(address(t2));
        vm.roll(block.number + 1); // block offset 1: 50% target
        address a = _agent();
        uint256 amount = _b(0.01 ether);
        _fund(a, amount);
        Currency c = Currency.wrap(base);
        uint256 before = VAULT.balanceOf(address(hook), c) + VAULT.balanceOf(address(t2.rewards()), c);
        vm.startPrank(a, a);
        IERC20(base).approve(address(router), amount);
        router.buy(k2, amount, 0, a);
        vm.stopPrank();
        uint256 fee = VAULT.balanceOf(address(hook), c) + VAULT.balanceOf(address(t2.rewards()), c) - before;
        assertEq(fee, amount * (100 + 100 + (5_000 - 100)) / 10_000, "base + .ai tax + anti-sniper");
    }

    function test_swapped_buyAndSellReportWhatTheTraderPaidAndGot() public {
        address a = _agent();
        uint256 amount = _b(0.03 ether);
        vm.recordLogs();
        uint256 got = _buy(a, amount);
        (bool isBuy, uint256 paid, uint256 tokens, uint160 price) = _swappedOf(address(token), a);
        assertTrue(isBuy);
        assertEq(paid, amount, "buy: bStock paid, fees included");
        assertEq(tokens, got);
        assertEq(price, _sqrtNow());

        uint256 before = IERC20(base).balanceOf(a);
        vm.recordLogs();
        _sell(a, got / 2);
        (isBuy, paid, tokens,) = _swappedOf(address(token), a);
        assertFalse(isBuy);
        assertEq(paid, IERC20(base).balanceOf(a) - before, "sell: bStock received, after fees");
        assertEq(tokens, got / 2);
    }

    // ------------------------------------------------------------------
    // tax period
    // ------------------------------------------------------------------

    function test_taxPeriod_altPoolsBlockedIncludingTheBStockPools() public {
        _afterAiWindow();
        _buy(outsider, _b(0.02 ether));
        address v2 = IPairFactoryS(PCS_V2_FACTORY).createPair(address(token), WBNB);
        address v3Base = IV3FactoryS(PCS_V3_FACTORY).createPool(address(token), base, 2500);
        assertEq(v3Base, KnownPools.v3Pool(address(token), base, 2500), "computed = real V3 pool against the bStock");
        address v2Base = IPairFactoryS(PCS_V2_FACTORY).createPair(address(token), base);
        assertTrue(token.isBlockedPool(v2Base));
        vm.startPrank(outsider, outsider);
        vm.expectRevert(abi.encodeWithSelector(StockToken.AltPoolBlocked.selector, v2));
        token.transfer(v2, 1 ether);
        vm.expectRevert(abi.encodeWithSelector(StockToken.AltPoolBlocked.selector, v3Base));
        token.transfer(v3Base, 1 ether);
        vm.expectRevert(abi.encodeWithSelector(StockToken.AltPoolBlocked.selector, v2Base));
        token.transfer(v2Base, 1 ether);
        vm.expectRevert(abi.encodeWithSelector(StockToken.AltPoolBlocked.selector, UNI_V4_PM));
        token.transfer(UNI_V4_PM, 1 ether);
        vm.stopPrank();

        vm.warp(token.taxEnd());
        vm.prank(outsider, outsider);
        token.transfer(v3Base, 1 ether);
        assertEq(token.balanceOf(v3Base), 1 ether, "free once the tax period is over");
    }

    function test_taxPeriod_permanentNeverEnds() public {
        StockLaunchFactory.CreateParams memory p = _params();
        p.taxSeconds = type(uint64).max;
        _useToken(p, 0);
        _afterHoldCap();
        _buy(outsider, _b(0.05 ether));
        vm.warp(block.timestamp + 3650 days);
        uint256 amount = _b(0.1 ether);
        uint256 before = _taken();
        _buy(outsider, amount);
        assertEq(_taken() - before, amount * 500 / 10_000, "still the normal rate");
    }

    function test_taxPeriod_universalRouterBuyAndSell() public {
        _afterHoldCap();
        uint256 amount = _b(0.1 ether);
        _fund(outsider, amount);
        uint256 before = _taken();
        _urSwap(outsider, true, amount, 1);
        uint256 bought = token.balanceOf(outsider);
        assertGt(bought, 0, "Universal Router buy (swap first, pay after) delivers");
        assertEq(_taken() - before, amount * 500 / 10_000, "same fee as through our router");

        uint256 baseBefore = IERC20(base).balanceOf(outsider);
        _urSwap(outsider, false, bought / 2, 1);
        assertEq(token.balanceOf(outsider), bought - bought / 2);
        assertGt(IERC20(base).balanceOf(outsider), baseBefore, "Universal Router sell pays out bStock");
    }

    // ------------------------------------------------------------------
    // buyback, rewards
    // ------------------------------------------------------------------

    function test_buyback_keeperBurnsAfterTheAiWindow() public {
        factory.setKeeper(address(this));
        vm.expectRevert(StockCurveHook.BuybackTooEarly.selector);
        hook.buyback(address(token), type(uint256).max, 0);

        _afterHoldCap();
        _buy(outsider, _b(1 ether));
        (,,, uint256 owedBefore) = hook.owedOf(address(token));
        uint256 deadBefore = token.balanceOf(DEAD);
        uint160 sqrtBefore = _sqrtNow();
        (uint256 spent, uint256 burned) = hook.buyback(address(token), type(uint256).max, 0);
        assertGt(spent, 0);
        assertEq(token.balanceOf(DEAD) - deadBefore, burned, "bought back and burned");
        (,,, uint256 owedAfter) = hook.owedOf(address(token));
        assertEq(owedBefore - owedAfter, spent, "paid from the buyback bucket");
        assertLt(_memePerBase(_sqrtNow()), _memePerBase(sqrtBefore), "the buyback raised the meme price");
        assertEq(
            VAULT.balanceOf(address(hook), Currency.wrap(base)),
            _bucketsOf(address(token)),
            "claims still match the buckets"
        );
    }

    function test_buyback_respectsTheKeepersBound() public {
        factory.setKeeper(address(this));
        _afterHoldCap();
        _buy(outsider, _b(1 ether));
        uint160 s = _sqrtNow();
        // a bound at the current price: nothing may be bought
        (uint256 spent,) = hook.buyback(address(token), type(uint256).max, s);
        assertEq(spent, 0, "bound already reached");
        vm.roll(block.number + 1);
        uint160 bound = _memeIs0() ? uint160(uint256(s) * 1001 / 1000) : uint160(uint256(s) * 999 / 1000);
        (spent,) = hook.buyback(address(token), type(uint256).max, bound);
        assertGt(spent, 0);
        uint160 after_ = _sqrtNow();
        if (_memeIs0()) assertLe(after_, bound, "never past the ceiling");
        else assertGe(after_, bound, "never past the floor");
    }

    function test_rewards_holdersEarnBStock() public {
        address a = _agent();
        _buy(a, _b(0.03 ether));
        address b = _agent();
        _buy(b, _b(0.03 ether));
        StockHolderRewards r = token.rewards();
        uint256 owedA = r.pending(a);
        assertGt(owedA, 0, "holder share accrued");
        uint256 before = IERC20(base).balanceOf(a);
        address[] memory batch = new address[](1);
        batch[0] = a;
        r.claimFor(batch);
        assertEq(IERC20(base).balanceOf(a) - before, owedA, "keeper pushed bStock to the holder");
        assertEq(r.pending(a), 0);
        assertEq(r.shareOf(address(hook)), 0, "hook excluded");
        assertEq(r.shareOf(address(VAULT)), 0, "vault excluded");

        assertEq(r.pending(b), 0, "b's own buy paid holders before b held anything");
        _buy(_agent(), _b(0.03 ether));
        uint256 owedB = r.pending(b);
        assertGt(owedB, 0);
        vm.prank(b);
        r.claim();
        assertEq(IERC20(base).balanceOf(b), owedB, "self claim in bStock");
    }

    // ------------------------------------------------------------------
    // launch switch
    // ------------------------------------------------------------------

    function test_switch_closedByDefaultOnlyOwnerCreates() public {
        StockLaunchFactory fresh = _newFactory(0);
        assertFalse(fresh.launchesOpen());
        vm.prank(creator, creator);
        vm.expectRevert(StockLaunchFactory.LaunchesClosed.selector);
        fresh.create(_params());
        StockToken first = fresh.create(_params());
        assertEq(first.creator(), address(this));
    }

    function test_switch_platformLaunchesFirstAndOpensInOneTransaction() public {
        StockLaunchFactory fresh = _newFactory(0.005 ether);
        vm.deal(address(this), 1 ether);
        StockToken first = fresh.createAndOpen{value: 0.005 ether}(_params());
        assertEq(first.creator(), address(this));
        assertTrue(fresh.launchesOpen());
        vm.prank(outsider, outsider);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", outsider));
        fresh.createAndOpen(_params());
    }

    function test_switch_ownershipMovesInTwoSteps() public {
        StockLaunchFactory fresh = _newFactory(0);
        address safe = makeAddr("platformSafe");
        fresh.transferOwnership(safe);
        assertEq(fresh.owner(), address(this));
        vm.prank(safe);
        fresh.acceptOwnership();
        assertEq(fresh.owner(), safe);
    }

    function _bucketsOf(address t) internal view returns (uint256) {
        (uint256 tr, uint256 f,, uint256 b) = hook.owedOf(t);
        return tr + f + b + hook.suanOwedOf(t);
    }
}

/// @dev NVDAB, meme sorts after it (bStock = currency0, as with BNB).
contract StockLaunchNvdabTest is StockLaunchTests {
    function _base() internal pure override returns (address) {
        return NVDAB;
    }

    function _memeIs0() internal pure override returns (bool) {
        return false;
    }
}

/// @dev NVDAB, meme forced to sort before it (meme = currency0).
contract StockLaunchNvdabMemeFirstTest is StockLaunchTests {
    function _base() internal pure override returns (address) {
        return NVDAB;
    }

    function _memeIs0() internal pure override returns (bool) {
        return true;
    }
}

/// @dev SPCXB, meme sorts before it (meme = currency0).
contract StockLaunchSpcxbTest is StockLaunchTests {
    function _base() internal pure override returns (address) {
        return SPCXB;
    }

    function _memeIs0() internal pure override returns (bool) {
        return true;
    }
}
