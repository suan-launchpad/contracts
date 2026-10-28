// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, Vm} from "forge-std/Test.sol";
import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {Currency} from "infinity-core/src/types/Currency.sol";
import {BalanceDelta} from "infinity-core/src/types/BalanceDelta.sol";
import {IHooks} from "infinity-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "infinity-core/src/interfaces/IPoolManager.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolIdLibrary} from "infinity-core/src/types/PoolId.sol";
import {IVault} from "infinity-core/src/interfaces/IVault.sol";
import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {TickMath} from "infinity-core/src/pool-cl/libraries/TickMath.sol";
import {ICLRouterBase} from "infinity-periphery/src/pool-cl/interfaces/ICLRouterBase.sol";
import {AgentLaunchFactory} from "../src/AgentLaunchFactory.sol";
import {AgentCurveHook} from "../src/AgentCurveHook.sol";
import {AgentToken} from "../src/AgentToken.sol";
import {AgentRouter} from "../src/AgentRouter.sol";
import {HolderRewards} from "../src/HolderRewards.sol";
import {KnownPools} from "../src/libraries/KnownPools.sol";

interface IAgentIdAdmin {
    function adminRegister(string calldata handle, address to) external;
    function owner() external view returns (address);
    function balanceOf(address) external view returns (uint256);
}

interface IUniversalRouter {
    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline) external payable;
}

interface IPermit2 {
    function approve(address token, address spender, uint160 amount, uint48 expiration) external;
}

interface IPancakeV2Factory {
    function createPair(address a, address b) external returns (address);
}

interface IPancakeV3Factory {
    function createPool(address a, address b, uint24 fee) external returns (address);
}

/// @notice BSC mainnet fork tests against the real PancakeSwap Infinity Vault / CLPoolManager and the real
///         SPACE ID Agent ID NFT. Test agents are minted on the fork by impersonating the NFT owner.
contract AgentLaunchTest is Test {
    using PoolIdLibrary for PoolKey;

    IVault constant VAULT = IVault(0x238a358808379702088667322f80aC48bAd5e6c4);
    ICLPoolManager constant CLPM = ICLPoolManager(0xa0FfB9c1CE1Fe56963B0321B32E7A0302114058b);
    address constant AGENT_ID = 0x60B9262456dE011F7d15a54CdD8c48bAaa8B022F;
    address constant UNI_V4_PM = 0x28e2Ea090877bF75740558f6BFB36A5ffeE9e9dF;
    address constant PCS_UR = 0xd9C500DfF816a1Da21A48A732d3498Bf09dc9AEB;
    address constant PERMIT2 = 0x31c2F6fcFf4F8759b3Bd5Bf0e1084A055615c768;
    address constant PCS_V2_FACTORY = 0xcA143Ce32Fe78f1f7019d7d551a6402fC5350c73;
    address constant PCS_V3_FACTORY = 0x0BFbCF9fa4f9C56B0F40a671Ad40E0805A091865;
    address constant UNI_V2_FACTORY = 0x8909Dc15e40173Ff4699343b6eB8132c65e18eC6;
    address constant UNI_V3_FACTORY = 0xdB1d10011AD0Ff90774D0C6Bb92e5C5c8b4461F7;
    address constant LIKWID_VAULT = 0x065d449ec9D139740343990B7E1CF05fA830e4Ba;
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;

    AgentLaunchFactory factory;
    AgentCurveHook hook;
    AgentRouter router;
    AgentToken token;
    PoolKey key;
    address treasury = makeAddr("treasury");
    address suanSink = makeAddr("suanSink");
    address creator = makeAddr("creator");
    address outsider = makeAddr("outsider");
    uint256 agentCount;
    address[] buyers;

    function setUp() public {
        vm.createSelectFork(vm.envOr("BSC_RPC_URL", string("https://bsc-dataseed.bnbchain.org")));
        // Label-derived test addresses have public keys, so on BSC mainnet they carry EIP-7702 delegations to sweepers
        // that forward any BNB they receive. Clear them so they behave like plain accounts on the fork.
        vm.etch(treasury, "");
        vm.etch(suanSink, "");
        vm.etch(creator, "");
        vm.etch(outsider, "");
        router = new AgentRouter(VAULT, CLPM);
        address[] memory routers = new address[](2);
        routers[0] = address(router);
        routers[1] = PCS_UR;
        factory = new AgentLaunchFactory(VAULT, CLPM, AGENT_ID, UNI_V4_PM, treasury, suanSink, routers, 0);
        hook = factory.hook();
        factory.setLaunchesOpen(true);
        vm.deal(creator, 10 ether);
        vm.deal(outsider, 10 ether);
        token = _launch(0.1 ether);
        key = hook.poolKeyOf(address(token));
        vm.roll(block.number + 10); // past the anti-sniper ladder; still inside the 2-minute .ai window
    }

    // ------------------------------------------------------------------
    // helpers
    // ------------------------------------------------------------------

    uint64 constant AI_ONLY = 2 minutes;
    uint64 constant HOLD_CAP_WINDOW = 1 hours;
    uint64 constant TAX_PERIOD = 15 days;

    function _params() internal pure returns (AgentLaunchFactory.CreateParams memory p) {
        p.name = "Agent Test";
        p.symbol = "AGT";
        p.buyTaxBps = 400;
        p.sellTaxBps = 400;
        p.agentBuyTaxBps = 100; // the normal rate is always this + 3 points
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

    function _launch(uint256 presale) internal returns (AgentToken t) {
        vm.prank(creator, creator);
        t = factory.create{value: presale}(_params());
    }

    function _useToken(AgentLaunchFactory.CreateParams memory p, uint256 presale) internal {
        vm.prank(creator, creator);
        token = factory.create{value: presale}(p);
        key = hook.poolKeyOf(address(token));
        vm.roll(block.number + 10);
    }

    function _agent() internal returns (address a) {
        agentCount++;
        string memory handle = string.concat("zqxdota", vm.toString(agentCount));
        a = makeAddr(handle);
        vm.prank(IAgentIdAdmin(AGENT_ID).owner());
        IAgentIdAdmin(AGENT_ID).adminRegister(handle, a);
        vm.deal(a, 100 ether);
    }

    function _buy(address who, uint256 bnb) internal returns (uint256) {
        return _buyTo(who, bnb, who);
    }

    function _buyTo(address who, uint256 bnb, address recipient) internal returns (uint256 out) {
        vm.prank(who, who);
        out = router.buy{value: bnb}(key, 0, 0, recipient);
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

    /// @dev BNB withheld as fees: what the hook keeps plus the holder share it passes straight to HolderRewards.
    function _taken() internal view returns (uint256) {
        return address(hook).balance + address(token.rewards()).balance;
    }

    /// @dev Single-pool exact-input swap through the real PancakeSwap Universal Router: INFI_SWAP with
    ///      CL_SWAP_EXACT_IN_SINGLE, SETTLE_ALL, TAKE_ALL (swap first, pay after, the router's standard plan).
    function _urSwap(address who, bool isBuy, uint256 amountIn, uint256 minOut) internal {
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(
            ICLRouterBase.CLSwapExactInputSingleParams({
                poolKey: key, zeroForOne: isBuy, amountIn: uint128(amountIn), amountOutMinimum: uint128(minOut), hookData: ""
            })
        );
        params[1] = abi.encode(isBuy ? key.currency0 : key.currency1, amountIn);
        params[2] = abi.encode(isBuy ? key.currency1 : key.currency0, minOut);
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(abi.encodePacked(uint8(0x06), uint8(0x0c), uint8(0x0f)), params);
        vm.prank(who, who);
        IUniversalRouter(PCS_UR).execute{value: isBuy ? amountIn : 0}(hex"10", inputs, block.timestamp);
    }

    function _factoryWithFee(uint256 fee) internal returns (AgentLaunchFactory f) {
        address[] memory routers = new address[](2);
        routers[0] = address(router);
        routers[1] = PCS_UR;
        f = new AgentLaunchFactory(VAULT, CLPM, AGENT_ID, UNI_V4_PM, treasury, suanSink, routers, fee);
    }

    function _swappedOf(address h, address t, address trader)
        internal
        view
        returns (bool isBuy, uint256 bnb, uint256 tokens, uint160 price)
    {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool found;
        for (uint256 i; i < logs.length; ++i) {
            Vm.Log memory l = logs[i];
            if (l.emitter != h || l.topics[0] != AgentCurveHook.Swapped.selector) continue;
            if (address(uint160(uint256(l.topics[1]))) != t || address(uint160(uint256(l.topics[2]))) != trader) continue;
            (isBuy, bnb, tokens, price) = abi.decode(l.data, (bool, uint256, uint256, uint160));
            found = true;
        }
        assertTrue(found, "Swapped emitted");
    }

    // ------------------------------------------------------------------
    // creation: one pool, whole supply, locked, trading from the first block
    // ------------------------------------------------------------------

    function test_create_wholeSupplyIsTheOnlyLiquidity() public view {
        (int24 lo, int24 hi, uint128 liq) = factory.position();
        assertEq(lo, TickMath.minUsableTick(10), "reaches every higher token price");
        assertEq(CLPM.getLiquidity(key.toId()), liq, "the launch position is the only liquidity");
        assertEq(token.totalSupply(), 1_000_000_000 ether);
        assertEq(token.balanceOf(address(hook)), 0, "the hook keeps no tokens");
        // start ~2.38e8 tokens per BNB: market cap 4.2 BNB
        assertApproxEqRel(uint256(TickMath.getSqrtRatioAtTick(hi)) ** 2 >> 192, 238_095_238, 0.002e18);
    }

    function test_create_pancakeProtocolFeeIsDynamicDefault() public view {
        (,, uint24 pf, uint24 lpFee) = CLPM.getSlot0(key.toId());
        assertEq(lpFee, 0, "native LP fee is zero; the hook withholds every fee in BNB");
        assertEq(pf & 0xfff, 300, "PancakeSwap default protocol fee for dynamic-fee pools: 0.03%");
    }

    function test_create_timesAreSetFromLaunch() public view {
        assertEq(token.aiOnlyUntil(), token.launchTime() + AI_ONLY);
        assertEq(token.holdCapUntil(), token.launchTime() + HOLD_CAP_WINDOW);
        assertEq(token.taxEnd(), token.launchTime() + TAX_PERIOD);
        AgentCurveHook.LaunchView memory v = hook.launchInfo(address(token));
        assertTrue(v.exists);
        assertEq(v.aiOnlyUntil, token.aiOnlyUntil());
        assertEq(v.holdCapUntil, token.holdCapUntil());
        assertEq(v.taxEnd, token.taxEnd());
        assertEq(v.buyTaxNowBps, 400);
        assertEq(v.wFounder, 40);
        assertEq(v.wHolder, 30);
        assertEq(v.wBurn, 20);
        assertEq(v.wLiquidity, 10);
        assertFalse(hook.launchInfo(address(0xBEEF)).exists, "unknown token: empty view");
    }

    function test_create_validatesWindows() public {
        AgentLaunchFactory.CreateParams memory p = _params();
        p.aiOnlySeconds = 1 minutes;
        vm.prank(creator, creator);
        vm.expectRevert(AgentLaunchFactory.InvalidAiOnly.selector);
        factory.create(p);

        p = _params();
        p.aiOnlySeconds = 31 minutes;
        vm.prank(creator, creator);
        vm.expectRevert(AgentLaunchFactory.InvalidAiOnly.selector);
        factory.create(p);

        p = _params();
        p.aiOnlySeconds = 30 minutes;
        p.holdCapSeconds = 10 minutes;
        vm.prank(creator, creator);
        vm.expectRevert(AgentLaunchFactory.InvalidHoldCap.selector);
        factory.create(p);

        p = _params();
        p.taxSeconds = 15 days - 1;
        vm.prank(creator, creator);
        vm.expectRevert(AgentLaunchFactory.InvalidTaxPeriod.selector);
        factory.create(p);

        p = _params();
        p.taxSeconds = 365 days + 1;
        vm.prank(creator, creator);
        vm.expectRevert(AgentLaunchFactory.InvalidTaxPeriod.selector);
        factory.create(p);

        p = _params();
        p.aiOnlySeconds = 30 minutes;
        p.holdCapSeconds = 30 minutes;
        p.taxSeconds = type(uint64).max;
        vm.prank(creator, creator);
        factory.create(p); // the bounds themselves, and a permanent tax period, are fine
    }

    function test_create_normalRateIsAlwaysAiRatePlusThree() public {
        assertEq(factory.normalRate(0), 300);
        assertEq(factory.normalRate(100), 400);
        assertEq(factory.normalRate(700), 1000, "the largest .ai rate: 7%");
        AgentLaunchFactory.CreateParams memory p = _params();
        p.buyTaxBps = 300; // a 2-point gap
        vm.prank(creator, creator);
        vm.expectRevert(AgentLaunchFactory.InvalidTax.selector);
        factory.create(p);
        p = _params();
        p.agentSellTaxBps = 800; // normal would be 11%
        p.sellTaxBps = 1100;
        vm.prank(creator, creator);
        vm.expectRevert(AgentLaunchFactory.InvalidTax.selector);
        factory.create(p);
    }

    function test_create_rejectsOversizedMeta() public {
        AgentLaunchFactory.CreateParams memory p = _params();
        p.meta = string(new bytes(129));
        vm.prank(creator, creator);
        vm.expectRevert(AgentLaunchFactory.InvalidMeta.selector);
        factory.create(p);
    }

    function test_create_storesMetaAndEmitsIt() public {
        AgentLaunchFactory.CreateParams memory p = _params();
        p.meta = "bafkreihdwdcefgh4dqkjv67uzcmw7ojee6xedzdetojuzjevtenxquvyku";
        vm.recordLogs();
        vm.prank(creator, creator);
        AgentToken t = factory.create(p);
        assertEq(t.meta(), p.meta, "the token keeps its metadata CID");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool found;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(factory) || logs[i].topics[0] != AgentLaunchFactory.TokenLaunched.selector) continue;
            (, string memory name, string memory symbol, string memory meta) = abi.decode(logs[i].data, (address, string, string, string));
            assertEq(name, p.name);
            assertEq(symbol, p.symbol);
            assertEq(meta, p.meta);
            found = true;
        }
        assertTrue(found, "TokenLaunched carries name, symbol and meta");
    }

    function test_create_sendsLaunchFeeToSuanBuyback() public {
        AgentLaunchFactory paid = _factoryWithFee(0.005 ether);
        paid.setLaunchesOpen(true);
        uint256 before = suanSink.balance;
        uint256 treasuryBefore = treasury.balance;
        vm.recordLogs();
        vm.prank(creator, creator);
        AgentToken t = paid.create{value: 0.105 ether}(_params());
        assertEq(suanSink.balance - before, 0.005 ether, "launch fee goes to the $SUAN buyback");
        assertEq(treasury.balance, treasuryBefore, "nothing to the treasury");
        (bool isBuy, uint256 bnb,,) = _swappedOf(address(paid.hook()), address(t), creator);
        assertTrue(isBuy);
        assertEq(bnb, 0.1 ether, "the rest is the creator presale");
    }

    function test_create_rejectsMissingLaunchFee() public {
        AgentLaunchFactory paid = _factoryWithFee(0.005 ether);
        paid.setLaunchesOpen(true);
        vm.prank(creator, creator);
        vm.expectRevert(abi.encodeWithSelector(AgentLaunchFactory.LaunchFeeRequired.selector, 0.005 ether));
        paid.create{value: 0.004 ether}(_params());
    }

    function test_lp_thirdPartyCannotAddLiquidity() public {
        LiquidityAdder adder = new LiquidityAdder(VAULT, CLPM);
        vm.expectRevert();
        adder.add(key);
    }

    function test_trade_bigBuysNeverRunOutOfLiquidity() public {
        _afterHoldCap();
        vm.deal(outsider, 1_000 ether);
        uint256 got = _buy(outsider, 500 ether);
        assertGt(got, 0);
        uint256 back = _sell(outsider, got);
        assertGt(back, 450 ether, "the same pool buys it back: only fees and price impact are lost");
    }

    // ------------------------------------------------------------------
    // creator presale: launch transaction, no .ai needed, at most 3% of the supply
    // ------------------------------------------------------------------

    function test_presale_exemptFromGateAndCap() public view {
        uint256 bal = token.balanceOf(creator);
        assertGt(bal, token.HOLD_CAP(), "creator presale is exempt from the 1% cap");
        assertEq(IAgentIdAdmin(AGENT_ID).balanceOf(creator), 0, "creator has no Agent ID");
    }

    function test_presale_overThreePercentReverts() public {
        vm.prank(creator, creator);
        vm.expectRevert(abi.encodeWithSelector(AgentCurveHook.PresaleCap.selector, 30_000_000 ether));
        factory.create{value: 0.2 ether}(_params());
    }

    function test_presale_paysTheCreatorsRate() public {
        vm.recordLogs();
        AgentToken t = _launch(0.1 ether);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool found;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(hook) || logs[i].topics[0] != AgentCurveHook.FeeTaken.selector) continue;
            if (address(uint160(uint256(logs[i].topics[1]))) != address(t)) continue;
            (bool isBuy, uint256 base, uint256 tax, uint256 anti) = abi.decode(logs[i].data, (bool, uint256, uint256, uint256));
            assertTrue(isBuy);
            assertEq(base, 0.1 ether * 100 / 10_000, "base fee 1%");
            assertEq(tax, 0.1 ether * 400 / 10_000, "creator has no .ai: normal 4%");
            assertEq(anti, 0);
            found = true;
        }
        assertTrue(found, "presale reports its fee like any buy");
    }

    // ------------------------------------------------------------------
    // .ai window (default 2 minutes)
    // ------------------------------------------------------------------

    function test_aiWindow_outsiderCannotBuy() public {
        vm.prank(outsider, outsider);
        vm.expectRevert();
        router.buy{value: 0.01 ether}(key, 0, 0, outsider);
    }

    function test_aiWindow_recipientMustBeAgent() public {
        address a = _agent();
        vm.prank(a, a);
        vm.expectRevert();
        router.buy{value: 0.01 ether}(key, 0, 0, outsider);
    }

    function test_aiWindow_walletTransfersLocked() public {
        address a = _agent();
        address b = _agent();
        _buy(a, 0.01 ether);
        vm.prank(a, a);
        vm.expectRevert(AgentToken.TransferLocked.selector);
        token.transfer(b, 1 ether);
    }

    function test_aiWindow_creatorCanSellWithoutAgentId() public {
        uint256 out = _sell(creator, token.balanceOf(creator) / 10);
        assertGt(out, 0);
    }

    function test_aiWindow_endsThenAnyoneBuys() public {
        _afterAiWindow();
        assertGt(_buy(outsider, 0.01 ether), 0, "outsiders buy once the .ai window is over");
        address friend = makeAddr("friend");
        vm.prank(outsider, outsider);
        token.transfer(friend, 1 ether);
        assertEq(token.balanceOf(friend), 1 ether, "wallet transfers are free after the .ai window");
    }

    function test_aiWindow_universalRouterBuyStillGated() public {
        vm.expectRevert();
        _urSwap(outsider, true, 0.01 ether, 1);
    }

    // ------------------------------------------------------------------
    // 1% hold cap (default 1 hour)
    // ------------------------------------------------------------------

    function test_holdCap_buyOverOnePercentReverts() public {
        address a = _agent();
        vm.prank(a, a);
        vm.expectRevert();
        router.buy{value: 0.5 ether}(key, 0, 0, a);
    }

    function test_holdCap_transfersCountToo() public {
        _afterAiWindow();
        address a = _agent();
        address b = _agent();
        _buy(a, 0.03 ether); // ~0.7% each
        _buy(b, 0.03 ether);
        uint256 bal = token.balanceOf(a);
        vm.prank(a, a);
        vm.expectRevert(abi.encodeWithSelector(AgentToken.HoldCap.selector, b));
        token.transfer(b, bal);
    }

    function test_holdCap_endsAfterItsWindow() public {
        _afterHoldCap();
        address a = _agent();
        assertGt(_buy(a, 1 ether), token.HOLD_CAP(), "no cap after the window");
    }

    function test_holdCap_buyOutputCannotBeMintedAsClaims() public {
        address a = _agent();
        VaultRoute route = new VaultRoute(VAULT, CLPM);
        uint256 before = token.balanceOf(a);
        vm.prank(a, a);
        route.run{value: 0.01 ether}(key, TickMath.MIN_SQRT_RATIO + 1, VaultRoute.Mode.MintClaims, a, 0.01 ether);
        assertEq(VAULT.balanceOf(address(route), key.currency1), 0, "no Vault claims of the token during the cap");
        assertGt(token.balanceOf(a) - before, 0, "the buy is delivered as ERC20 to the trader");
    }

    function test_holdCap_claimsCannotBypassIt() public {
        address a = _agent();
        VaultRoute route = new VaultRoute(VAULT, CLPM);
        vm.prank(a, a);
        vm.expectRevert(); // HoldCap, wrapped by the Vault and the pool manager
        route.run{value: 0.5 ether}(key, TickMath.MIN_SQRT_RATIO + 1, VaultRoute.Mode.MintClaims, a, 0.5 ether);
    }

    // ------------------------------------------------------------------
    // fees: 1% base (platform 0.5 to $SUAN buyback + creator 0.5) plus identity tax, all in BNB
    // ------------------------------------------------------------------

    function test_fees_agentBuySplit() public {
        address a = _agent();
        uint256 rewardsBnb = address(token.rewards()).balance;
        uint256 before = _taken();
        (uint256 t0, uint256 f0,, uint256 b0) = hook.owedOf(address(token));
        uint256 s0 = hook.suanOwedOf(address(token));
        uint256 out = _buy(a, 0.03 ether);
        assertEq(token.balanceOf(a), out);

        uint256 base = 0.03 ether * 100 / 10_000;
        uint256 tax = 0.03 ether * 100 / 10_000; // .ai rate 1%
        assertEq(_taken() - before, base + tax, "fee withheld in BNB");
        (uint256 t1, uint256 f1, uint256 h1, uint256 b1) = hook.owedOf(address(token));
        assertEq(f1 - f0, base / 2 + tax * 40 / 100, "creator: half the base fee + 40% of the tax");
        assertEq(h1, 0, "holder bucket never waits");
        assertEq(address(token.rewards()).balance - rewardsBnb, tax * 30 / 100, "holders 30%, deposited with the trade");
        assertEq(b1 - b0, tax * 20 / 100, "burn 20% -> buyback");
        assertEq(hook.suanOwedOf(address(token)) - s0, base - base / 2, "platform half -> $SUAN buyback");
        assertEq(t1 - t0, tax - tax * 40 / 100 - tax * 30 / 100 - tax * 20 / 100, "treasury: the liquidity share only");
    }

    function test_fees_outsiderPaysNormalRateAgentPaysAiRate() public {
        _afterAiWindow();
        uint256 before = _taken();
        _buy(outsider, 0.02 ether);
        assertEq(_taken() - before, 0.02 ether * 500 / 10_000, "outsider: 1% + 4%");
        address a = _agent();
        before = _taken();
        _buy(a, 0.02 ether);
        assertEq(_taken() - before, 0.02 ether * 200 / 10_000, ".ai: 1% + 1%");
    }

    /// @dev The 3-point surcharge of wallets without .ai always goes to buyback & burn, whatever the weights: a creator
    ///      buying through its own wallets (bundling) cannot get it back.
    function test_fees_surchargeAlwaysBurnsNeverPaysTheCreator() public {
        AgentLaunchFactory.CreateParams memory p = _params();
        p.wFounder = 100;
        p.wHolder = 0;
        p.wBurn = 0;
        p.wLiquidity = 0;
        _useToken(p, 0);
        _afterAiWindow();
        (uint256 t0, uint256 f0, , uint256 b0) = hook.owedOf(address(token));
        uint256 s0 = hook.suanOwedOf(address(token));
        _buy(outsider, 0.02 ether);
        (uint256 t1, uint256 f1, , uint256 b1) = hook.owedOf(address(token));
        uint256 base = 0.02 ether * 100 / 10_000;
        assertEq(f1 - f0, base / 2 + 0.02 ether * 100 / 10_000, "creator: its 0.5% + the .ai-rate part only");
        assertEq(b1 - b0, 0.02 ether * 300 / 10_000, "the 3% surcharge: all to buyback");
        assertEq(hook.suanOwedOf(address(token)) - s0, base - base / 2, "platform: its 0.5% to the $SUAN buyback");
        assertEq(t1, t0, "nothing to the treasury");

        // after the tax period there is no surcharge
        vm.warp(token.taxEnd());
        (,, , uint256 b2) = hook.owedOf(address(token));
        _buy(outsider, 0.02 ether);
        (,, , uint256 b3) = hook.owedOf(address(token));
        assertEq(b3, b2, "no surcharge, so nothing to the token's own buyback");
    }

    function test_fees_sellFeeTakenFromBnbOut() public {
        address a = _agent();
        uint256 got = _buy(a, 0.03 ether);
        uint256 before = _taken();
        uint256 bnbOut = _sell(a, got / 2);
        uint256 fee = _taken() - before;
        assertGt(bnbOut, 0);
        assertApproxEqAbs(fee, (bnbOut + fee) * 200 / 10_000, 2, "1% base + 1% .ai rate of gross BNB out");
    }

    function test_fees_afterTaxPeriodEveryonePaysTheAiRate() public {
        vm.warp(token.taxEnd());
        uint256 before = _taken();
        _buy(outsider, 0.1 ether);
        assertEq(_taken() - before, 0.1 ether * 200 / 10_000, "outsider now pays the .ai rate");
        assertEq(hook.launchInfo(address(token)).buyTaxNowBps, 100);
    }

    function test_fees_platformHalfAlwaysToSuanBuyback() public {
        AgentLaunchFactory.CreateParams memory p = _params();
        p.buyTaxBps = 300;
        p.sellTaxBps = 300;
        p.agentBuyTaxBps = 0;
        p.agentSellTaxBps = 0;
        _useToken(p, 0);
        _afterHoldCap();
        address a = _agent();
        (uint256 t0, uint256 f0,, uint256 b0) = hook.owedOf(address(token));
        uint256 s0 = hook.suanOwedOf(address(token));
        _buy(a, 0.1 ether);
        (uint256 t1, uint256 f1,, uint256 b1) = hook.owedOf(address(token));
        uint256 s1 = hook.suanOwedOf(address(token));
        assertEq(s1 - s0, 0.1 ether * 50 / 10_000, "platform 0.5% -> $SUAN buyback from the first trade");
        assertEq(f1 - f0, 0.1 ether * 50 / 10_000, "creator 0.5%");
        assertEq(t1, t0, "nothing to the treasury");
        assertEq(b1, b0, "nothing to the token's own buyback");

        vm.warp(token.launchTime() + 30 days);
        _buy(a, 0.1 ether);
        (uint256 t2, uint256 f2,, uint256 b2) = hook.owedOf(address(token));
        assertEq(hook.suanOwedOf(address(token)) - s1, 0.1 ether * 50 / 10_000, "still to the $SUAN buyback later on");
        assertEq(t2, t1);
        assertEq(b2, b1);
        assertEq(f2 - f1, 0.1 ether * 50 / 10_000, "the creator keeps its half");

        uint256 sinkBefore = suanSink.balance;
        uint256 owed = hook.suanOwedOf(address(token));
        hook.dispatch(address(token));
        assertEq(suanSink.balance - sinkBefore, owed, "dispatch pays the $SUAN bucket to the sink");
        assertEq(hook.suanOwedOf(address(token)), 0);
    }

    function test_fees_creatorCanSendItsShareToHolders() public {
        vm.prank(outsider);
        vm.expectRevert(AgentCurveHook.NotCreator.selector);
        hook.setCreatorShareToHolders(address(token));

        vm.prank(creator);
        hook.setCreatorShareToHolders(address(token));
        assertTrue(hook.launchInfo(address(token)).creatorShareToHolders);

        address a = _agent();
        (, uint256 f0,,) = hook.owedOf(address(token));
        uint256 rewardsBnb = address(token.rewards()).balance;
        _buy(a, 0.02 ether);
        (, uint256 f1,,) = hook.owedOf(address(token));
        uint256 tax = 0.02 ether * 100 / 10_000;
        assertEq(f1 - f0, tax * 40 / 100, "creator keeps only its tax share");
        assertEq(address(token.rewards()).balance - rewardsBnb, 0.02 ether * 50 / 10_000 + tax * 30 / 100, "base half goes to holders");
    }

    function test_fees_antiSniperLadder() public {
        AgentToken t2 = _launch(0);
        PoolKey memory k2 = hook.poolKeyOf(address(t2));
        vm.roll(block.number + 1); // block offset 1: 50% target
        address a = _agent();
        uint256 before = address(hook).balance + address(t2.rewards()).balance;
        vm.prank(a, a);
        router.buy{value: 0.01 ether}(k2, 0, 0, a);
        uint256 fee = address(hook).balance + address(t2.rewards()).balance - before;
        assertEq(fee, 0.01 ether * (100 + 100 + (5_000 - 100)) / 10_000, "base + .ai tax + anti-sniper");
    }

    /// @dev The platform's first coin: .ai 0%, others 3%; tax split 50% .ai holder rewards / 50% buyback-and-burn.
    function test_fees_platformFirstCoinSetup() public {
        AgentLaunchFactory.CreateParams memory p = _params();
        p.buyTaxBps = 300;
        p.sellTaxBps = 300;
        p.agentBuyTaxBps = 0;
        p.agentSellTaxBps = 0;
        p.wFounder = 0;
        p.wHolder = 50;
        p.wBurn = 50;
        p.wLiquidity = 0;
        p.agentOnlyRewards = true;
        _useToken(p, 0);
        address a = _agent();
        uint256 before = _taken();
        _buy(a, 0.01 ether);
        assertEq(_taken() - before, 0.01 ether * 100 / 10_000, ".ai: base fee only");
        _afterHoldCap();
        before = _taken();
        _buy(outsider, 0.1 ether);
        assertEq(_taken() - before, 0.1 ether * 400 / 10_000, "no .ai: 1% + 3%");
        assertTrue(HolderRewards(token.rewards()).agentOnly(), "holder rewards for .ai wallets only");
    }

    function test_swapped_buyAndSellReportWhatTheTraderPaidAndGot() public {
        address a = _agent();
        vm.recordLogs();
        uint256 got = _buy(a, 0.03 ether);
        (bool isBuy, uint256 bnb, uint256 tokens, uint160 price) = _swappedOf(address(hook), address(token), a);
        (uint160 sqrtNow,,,) = CLPM.getSlot0(key.toId());
        assertTrue(isBuy);
        assertEq(bnb, 0.03 ether, "buy: BNB paid, fees included");
        assertEq(tokens, got, "buy: tokens received");
        assertEq(price, sqrtNow, "price after the trade");

        uint256 bnbBefore = a.balance;
        vm.recordLogs();
        _sell(a, got / 2);
        (isBuy, bnb, tokens,) = _swappedOf(address(hook), address(token), a);
        assertFalse(isBuy);
        assertEq(bnb, a.balance - bnbBefore, "sell: BNB received, after fees");
        assertEq(tokens, got / 2, "sell: tokens sold");
    }

    // ------------------------------------------------------------------
    // tax period = anti-farm window (at least 15 days, or permanent)
    // ------------------------------------------------------------------

    function test_taxPeriod_altPoolsBlockedThenFree() public {
        _afterAiWindow();
        _buy(outsider, 0.02 ether);
        address v2 = IPancakeV2Factory(PCS_V2_FACTORY).createPair(address(token), KnownPools.WBNB);
        assertEq(v2, KnownPools.v2Pair(address(token), KnownPools.WBNB));
        address v3 = IPancakeV3Factory(PCS_V3_FACTORY).createPool(address(token), KnownPools.WBNB, 2500);
        assertEq(v3, KnownPools.v3Pool(address(token), KnownPools.WBNB, 2500));
        vm.startPrank(outsider, outsider);
        vm.expectRevert(abi.encodeWithSelector(AgentToken.AltPoolBlocked.selector, v2));
        token.transfer(v2, 1 ether);
        vm.expectRevert(abi.encodeWithSelector(AgentToken.AltPoolBlocked.selector, UNI_V4_PM));
        token.transfer(UNI_V4_PM, 1 ether);
        vm.stopPrank();

        vm.warp(token.taxEnd());
        vm.prank(outsider, outsider);
        token.transfer(v2, 1 ether);
        assertEq(token.balanceOf(v2), 1 ether, "free once the tax period is over");
    }

    function test_taxPeriod_uniswapPoolsAndLikwidVaultBlocked() public {
        _afterAiWindow();
        _buy(outsider, 0.02 ether);
        address uniV2 = IPancakeV2Factory(UNI_V2_FACTORY).createPair(address(token), KnownPools.WBNB);
        address uniV3 = IPancakeV3Factory(UNI_V3_FACTORY).createPool(address(token), KnownPools.WBNB, 3000);
        assertEq(uniV2, KnownPools.uniV2Pair(address(token), KnownPools.WBNB), "computed = real Uniswap V2 pair");
        assertEq(uniV3, KnownPools.uniV3Pool(address(token), KnownPools.WBNB, 3000), "computed = real Uniswap V3 pool");
        address[3] memory venues = [uniV2, uniV3, LIKWID_VAULT];
        vm.startPrank(outsider, outsider);
        for (uint256 i; i < venues.length; ++i) {
            vm.expectRevert(abi.encodeWithSelector(AgentToken.AltPoolBlocked.selector, venues[i]));
            token.transfer(venues[i], 1 ether);
        }
        vm.stopPrank();
    }

    function test_taxPeriod_permanentNeverEnds() public {
        AgentLaunchFactory.CreateParams memory p = _params();
        p.symbol = "PRM";
        p.taxSeconds = type(uint64).max;
        _useToken(p, 0);
        assertEq(token.taxEnd(), type(uint64).max);
        _afterHoldCap();
        _buy(outsider, 0.05 ether);
        address v2 = IPancakeV2Factory(PCS_V2_FACTORY).createPair(address(token), KnownPools.WBNB);
        vm.warp(block.timestamp + 3650 days);
        vm.prank(outsider, outsider);
        vm.expectRevert(abi.encodeWithSelector(AgentToken.AltPoolBlocked.selector, v2));
        token.transfer(v2, 1 ether);
        uint256 before = _taken();
        _buy(outsider, 0.1 ether);
        assertEq(_taken() - before, 0.1 ether * 500 / 10_000, "still the normal rate");
    }

    function test_taxPeriod_altPoolLiquidityAfterOwnSwapBlocked() public {
        _afterHoldCap();
        _buy(outsider, 0.05 ether);
        VaultRoute route = new VaultRoute(VAULT, CLPM);
        vm.startPrank(outsider, outsider);
        token.approve(address(route), type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(AgentToken.AltPoolBlocked.selector, address(VAULT)));
        route.run{value: 0.01 ether}(key, TickMath.MIN_SQRT_RATIO + 1, VaultRoute.Mode.AltPoolLiquidity, outsider, 0.001 ether);
        vm.stopPrank();
    }

    function test_aiWindow_altPoolLiquidityAfterOwnSwapBlocked() public {
        address a = _agent();
        _buy(a, 0.03 ether);
        VaultRoute route = new VaultRoute(VAULT, CLPM);
        vm.startPrank(a, a);
        token.approve(address(route), type(uint256).max);
        vm.expectRevert(AgentToken.TransferLocked.selector);
        route.run{value: 0.01 ether}(key, TickMath.MIN_SQRT_RATIO + 1, VaultRoute.Mode.AltPoolLiquidity, a, 0.001 ether);
        vm.stopPrank();
    }

    function test_taxPeriod_vaultInflowIsExactlyWhatOwnPoolSold() public {
        _afterHoldCap();
        _buy(outsider, 0.05 ether);
        VaultRoute route = new VaultRoute(VAULT, CLPM);
        vm.startPrank(outsider, outsider);
        token.approve(address(route), type(uint256).max);
        // sells 1000 tokens in our pool but sends 1001 to the Vault, keeping the extra as a claim
        vm.expectRevert(abi.encodeWithSelector(AgentToken.AltPoolBlocked.selector, address(VAULT)));
        route.run(key, TickMath.MAX_SQRT_RATIO - 1, VaultRoute.Mode.SellOverpay, outsider, 1_000 ether);
        route.run(key, TickMath.MAX_SQRT_RATIO - 1, VaultRoute.Mode.SellExact, outsider, 1_000 ether);
        vm.stopPrank();
    }

    function test_taxPeriod_ownPoolWorksDirectlyThroughTheVault() public {
        _afterHoldCap();
        VaultRoute route = new VaultRoute(VAULT, CLPM);
        vm.prank(outsider, outsider);
        route.run{value: 0.01 ether}(key, TickMath.MIN_SQRT_RATIO + 1, VaultRoute.Mode.TakeOnly, outsider, 0.01 ether);
        assertGt(token.balanceOf(outsider), 0, "a plain swap + take in our own pool is not affected");
    }

    function test_taxPeriod_universalRouterBuyAndSell() public {
        _afterHoldCap();
        uint256 before = _taken();
        _urSwap(outsider, true, 0.1 ether, 1);
        uint256 bought = token.balanceOf(outsider);
        assertGt(bought, 0, "Universal Router buy delivers");
        assertEq(_taken() - before, 0.1 ether * 500 / 10_000, "same fee as through our router");

        vm.startPrank(outsider, outsider);
        token.approve(PERMIT2, type(uint256).max);
        IPermit2(PERMIT2).approve(address(token), PCS_UR, type(uint160).max, uint48(block.timestamp + 1 days));
        vm.stopPrank();
        uint256 bnbBefore = outsider.balance;
        _urSwap(outsider, false, bought / 2, 1);
        assertEq(token.balanceOf(outsider), bought - bought / 2);
        assertGt(outsider.balance, bnbBefore, "Universal Router sell pays out");
    }

    // ------------------------------------------------------------------
    // buyback, payouts, rewards
    // ------------------------------------------------------------------

    function test_buyback_keeperBurnsAfterTheAiWindow() public {
        factory.setKeeper(address(this));
        vm.expectRevert(AgentCurveHook.BuybackTooEarly.selector);
        hook.buyback(address(token), type(uint256).max, 0);

        _afterHoldCap();
        _buy(outsider, 1 ether); // burn share of the tax
        uint256 deadBefore = token.balanceOf(DEAD);
        (uint256 spent, uint256 burned) = hook.buyback(address(token), type(uint256).max, 0);
        assertGt(spent, 0);
        assertEq(token.balanceOf(DEAD) - deadBefore, burned, "bought back and burned");
    }

    function test_rewards_holdersEarnBnb() public {
        address a = _agent();
        _buy(a, 0.03 ether);
        address b = _agent();
        _buy(b, 0.03 ether);
        HolderRewards r = token.rewards();
        assertGt(r.pending(a), 0, "holder share accrued");
        uint256 before = a.balance;
        address[] memory batch = new address[](1);
        batch[0] = a;
        r.claimFor(batch);
        assertGt(a.balance, before, "keeper pushed BNB to the holder");
        assertEq(r.shareOf(address(hook)), 0, "hook excluded");
        assertEq(r.shareOf(address(VAULT)), 0, "vault excluded");
    }

    // ------------------------------------------------------------------
    // launch switch: deployed closed, the platform launches first, then opens creation to everyone
    // ------------------------------------------------------------------

    function test_switch_closedByDefaultOnlyOwnerCreates() public {
        AgentLaunchFactory fresh = _factoryWithFee(0);
        assertFalse(fresh.launchesOpen(), "deployed closed");
        vm.prank(creator, creator);
        vm.expectRevert(AgentLaunchFactory.LaunchesClosed.selector);
        fresh.create(_params());
        vm.deal(address(this), 1 ether);
        AgentToken first = fresh.create(_params());
        assertEq(first.creator(), address(this));
    }

    function test_switch_ownerOpensThenAnyoneCreates() public {
        AgentLaunchFactory fresh = _factoryWithFee(0);
        vm.expectEmit(address(fresh));
        emit AgentLaunchFactory.LaunchesOpened(true);
        fresh.setLaunchesOpen(true);
        vm.prank(creator, creator);
        fresh.create(_params());
    }

    function test_switch_platformLaunchesFirstAndOpensInOneTransaction() public {
        AgentLaunchFactory fresh = _factoryWithFee(0.005 ether);
        vm.deal(address(this), 1 ether);
        vm.expectEmit(address(fresh));
        emit AgentLaunchFactory.LaunchesOpened(true);
        AgentToken first = fresh.createAndOpen{value: 0.005 ether}(_params());
        assertEq(first.creator(), address(this), "the platform is the first creator");
        assertTrue(fresh.launchesOpen());
        vm.prank(creator, creator);
        fresh.create{value: 0.005 ether}(_params());
    }

    function test_switch_onlyOwnerLaunchesAndOpens() public {
        AgentLaunchFactory fresh = _factoryWithFee(0);
        vm.prank(creator, creator);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", creator));
        fresh.createAndOpen(_params());
    }

    function test_switch_onlyOwnerToggles() public {
        AgentLaunchFactory fresh = _factoryWithFee(0);
        vm.prank(outsider);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", outsider));
        fresh.setLaunchesOpen(true);
    }

    function test_switch_closingAgainLeavesExistingTokensTrading() public {
        factory.setLaunchesOpen(false);
        address a = _agent();
        assertGt(_buy(a, 0.01 ether), 0, "existing launches keep trading while creation is closed");
        vm.prank(creator, creator);
        vm.expectRevert(AgentLaunchFactory.LaunchesClosed.selector);
        factory.create(_params());
    }

    function test_switch_ownershipMovesInTwoSteps() public {
        AgentLaunchFactory fresh = _factoryWithFee(0);
        address safe = makeAddr("platformSafe");
        fresh.transferOwnership(safe);
        assertEq(fresh.owner(), address(this), "pending until accepted");
        vm.prank(safe);
        fresh.acceptOwnership();
        assertEq(fresh.owner(), safe);
    }
}

/// @dev Tries to add liquidity to a hooked pool as a third party.
contract LiquidityAdder {
    IVault immutable vault;
    ICLPoolManager immutable pm;
    PoolKey internal k;

    constructor(IVault v, ICLPoolManager p) {
        vault = v;
        pm = p;
    }

    function add(PoolKey calldata key) external {
        k = key;
        vault.lock("");
    }

    function lockAcquired(bytes calldata) external returns (bytes memory) {
        pm.modifyLiquidity(
            k, ICLPoolManager.ModifyLiquidityParams({tickLower: -887270, tickUpper: 887270, liquidityDelta: 1e18, salt: 0}), ""
        );
        return "";
    }
}

/// @dev Works with the Vault directly, as an aggregator or an attacker contract can: buy in the hooked pool, then use
///      the bought tokens (or other tokens) elsewhere inside the same lock.
contract VaultRoute {
    enum Mode {
        TakeOnly,
        MintClaims,
        AltPoolLiquidity,
        SellExact,
        SellOverpay
    }

    IVault immutable vault;
    ICLPoolManager immutable pm;

    constructor(IVault v, ICLPoolManager p) {
        vault = v;
        pm = p;
    }

    receive() external payable {}

    /// @param payer receives the bought tokens and pays the alt-pool or sold tokens (approve this contract)
    /// @param bnbIn BNB spent in the hooked pool (tokens sold, for the sell modes); the rest of msg.value pays the
    ///        alt pool's BNB side
    function run(PoolKey calldata ours, uint160 limit, Mode mode, address payer, uint256 bnbIn) external payable {
        vault.lock(abi.encode(ours, limit, mode, payer, bnbIn));
    }

    function lockAcquired(bytes calldata data) external returns (bytes memory) {
        (PoolKey memory ours, uint160 limit, Mode mode, address payer, uint256 bnbIn) =
            abi.decode(data, (PoolKey, uint160, Mode, address, uint256));
        if (mode == Mode.SellExact || mode == Mode.SellOverpay) {
            BalanceDelta sd = pm.swap(
                ours, ICLPoolManager.SwapParams({zeroForOne: false, amountSpecified: -int256(bnbIn), sqrtPriceLimitX96: limit}), ""
            );
            uint256 extra = mode == Mode.SellOverpay ? 1 ether : 0;
            vault.sync(ours.currency1);
            IERC20(Currency.unwrap(ours.currency1)).transferFrom(payer, address(vault), uint256(uint128(-sd.amount1())) + extra);
            vault.settle();
            if (extra > 0) vault.mint(address(this), ours.currency1, extra);
            vault.take(ours.currency0, payer, uint256(uint128(sd.amount0())));
            return "";
        }
        BalanceDelta d = pm.swap(
            ours, ICLPoolManager.SwapParams({zeroForOne: true, amountSpecified: -int256(bnbIn), sqrtPriceLimitX96: limit}), ""
        );
        vault.settle{value: uint256(uint128(-d.amount0()))}();
        uint256 out = uint256(uint128(d.amount1()));
        if (mode == Mode.MintClaims) {
            if (out > 0) vault.mint(address(this), ours.currency1, out);
            return "";
        }
        if (out > 0) vault.take(ours.currency1, payer, out);
        if (mode == Mode.TakeOnly) return "";

        // a fee-free pool for the same pair, no hook
        PoolKey memory alt = PoolKey({
            currency0: ours.currency0,
            currency1: ours.currency1,
            hooks: IHooks(address(0)),
            poolManager: IPoolManager(address(pm)),
            fee: 100,
            parameters: bytes32(uint256(60) << 16)
        });
        (uint160 sqrtP,,,) = pm.getSlot0(PoolIdLibrary.toId(ours));
        pm.initialize(alt, sqrtP);
        (BalanceDelta ld,) = pm.modifyLiquidity(
            alt, ICLPoolManager.ModifyLiquidityParams({tickLower: -887220, tickUpper: 887220, liquidityDelta: 1e18, salt: 0}), ""
        );
        vault.sync(alt.currency1);
        IERC20(Currency.unwrap(alt.currency1)).transferFrom(payer, address(vault), uint256(uint128(-ld.amount1())));
        vault.settle();
        vault.settle{value: uint256(uint128(-ld.amount0()))}();
        return "";
    }
}
