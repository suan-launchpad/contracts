// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "./StockLaunch.t.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {BalanceDelta} from "infinity-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta} from "infinity-core/src/types/BeforeSwapDelta.sol";
import {StockTokenDeployer} from "../src/StockTokenDeployer.sol";
import {V3Path} from "../src/libraries/V3Path.sol";

interface IQuoterV2S {
    function quoteExactInput(bytes memory path, uint256 amountIn)
        external
        returns (uint256 amountOut, uint160[] memory, uint32[] memory, uint256);
}

/// A base the owner could (wrongly) allowlist: re-enters the hook whenever the Vault pays it out.
contract ReentrantBase is ERC20 {
    address constant VAULT = 0x238a358808379702088667322f80aC48bAd5e6c4;
    StockCurveHook public hook;
    address public token;
    bool public useDispatch;

    constructor() ERC20("Reentrant", "RE") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function arm(StockCurveHook h, address t, bool viaDispatch) external {
        hook = h;
        token = t;
        useDispatch = viaDispatch;
    }

    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);
        if (from == VAULT && address(hook) != address(0)) {
            if (useDispatch) hook.dispatch(token);
            else hook.claimFounder(token);
        }
    }
}

/// Refuses BNB.
contract RejectingRecipient {
    receive() external payable {
        revert("no");
    }
}

/// Tries to re-enter the router when it is paid BNB.
contract ReenteringRecipient {
    StockRouter public router;
    PoolKey public k;

    function arm(StockRouter r, PoolKey calldata key_) external {
        router = r;
        k = key_;
    }

    receive() external payable {
        router.sell(k, 1, 0, address(this));
    }
}

/// A contract that drives the trusted router on behalf of whoever calls it.
contract RouterProxy {
    function buy(StockRouter r, PoolKey calldata k, IERC20 b, uint256 amount, address to) external {
        b.transferFrom(msg.sender, address(this), amount);
        b.approve(address(r), amount);
        r.buy(k, amount, 0, to);
    }
}

/// Buys, tries to trigger a buyback inside the same transaction, sells.
contract StockBuybackSandwich {
    function run(StockRouter r, StockCurveHook h, PoolKey calldata k, IERC20 b, IERC20 t, uint256 amount) external {
        b.approve(address(r), amount);
        r.buy(k, amount, 0, address(this));
        try h.buyback(address(t), type(uint256).max, 0) {} catch {}
        uint256 bal = t.balanceOf(address(this));
        t.approve(address(r), bal);
        r.sell(k, bal, 0, address(this));
    }
}

/// Buys, tries to collect rewards, sells, all in one transaction.
contract StockRewardSniper {
    function run(StockRouter r, StockCurveHook h, PoolKey calldata k, IERC20 b, StockToken t, uint256 amount) external {
        b.approve(address(r), amount);
        r.buy(k, amount, 0, address(this));
        h.dispatch(address(t));
        t.rewards().claim();
        uint256 bal = t.balanceOf(address(this));
        t.approve(address(r), bal);
        r.sell(k, bal, 0, address(this));
    }
}

/// @notice BNB legs (StockRouter, StockFeeSink → SuanBuyBurn), refusing bStocks (pause, blocklist) and the security
///         regressions of Security.t.sol, for stock memes.
abstract contract StockSecurityTests is StockLaunchBase {
    using PoolIdLibrary for PoolKey;

    // ------------------------------------------------------------------
    // StockRouter: BNB in and out
    // ------------------------------------------------------------------

    function test_router_buyWithBnbKeepsTheTradersIdentity() public {
        address a = _agent();
        vm.recordLogs();
        vm.prank(a, a);
        uint256 out = router.buyWithBnb{value: 0.01 ether}(key, _buyPath(), 1, 1, a);
        assertGt(out, 0);
        assertEq(token.balanceOf(a), out, "a .ai wallet buys with BNB in the .ai window");
        (bool isBuy, uint256 paid,,) = _swappedOf(address(token), a);
        assertTrue(isBuy);
        assertGt(paid, 0, "the V3 leg bought bStock for the pool");
        _assertRouterEmpty();
    }

    function test_router_buyWithBnbGatedForOutsiders() public {
        bytes memory path = _buyPath();
        vm.prank(outsider, outsider);
        vm.expectRevert();
        router.buyWithBnb{value: 0.01 ether}(key, path, 1, 1, outsider);
    }

    function test_router_contractCannotActForAnAgent() public {
        address a = _agent();
        RouterProxy proxy = new RouterProxy();
        uint256 amount = _b(0.01 ether);
        _fund(a, amount);
        vm.startPrank(a, a);
        IERC20(base).approve(address(proxy), amount);
        vm.expectRevert(); // RouterMismatch: the router's msgSender is the proxy, not the .ai wallet
        proxy.buy(router, key, IERC20(base), amount, a);
        vm.stopPrank();
    }

    function test_router_buyWithBnbThenSellForBnb() public {
        _afterHoldCap();
        bytes memory buyPath = _buyPath();
        bytes memory sellPath = _sellPath();
        vm.prank(outsider, outsider);
        uint256 got = router.buyWithBnb{value: 0.05 ether}(key, buyPath, 1, 1, outsider);
        assertGt(got, 0);
        uint256 before = outsider.balance;
        vm.startPrank(outsider, outsider);
        token.approve(address(router), got);
        uint256 bnbOut = router.sellForBnb(key, got, sellPath, 1, outsider);
        vm.stopPrank();
        assertEq(outsider.balance - before, bnbOut, "sold to BNB");
        assertGt(bnbOut, 0.04 ether, "round trip loses only fees and pool impact");
        assertLt(bnbOut, 0.05 ether);
        _assertRouterEmpty();
    }

    function test_router_minOutsProtect() public {
        _afterHoldCap();
        bytes memory path = _buyPath();
        vm.prank(outsider, outsider);
        vm.expectRevert(); // V3 leg below minBaseOut
        router.buyWithBnb{value: 0.01 ether}(key, path, type(uint256).max, 1, outsider);
        vm.prank(outsider, outsider);
        vm.expectRevert(); // meme out below minOut
        router.buyWithBnb{value: 0.01 ether}(key, path, 1, type(uint256).max, outsider);

        uint256 got = _buy(outsider, _b(0.01 ether));
        bytes memory sellPath = _sellPath();
        vm.startPrank(outsider, outsider);
        token.approve(address(router), got);
        vm.expectRevert();
        router.sellForBnb(key, got, sellPath, type(uint256).max, outsider);
        vm.expectRevert();
        router.sell(key, got, type(uint256).max, outsider);
        vm.stopPrank();
    }

    function test_router_rejectsPathsThatDoNotMatchThePool() public {
        bytes memory wrongEnd = abi.encodePacked(WBNB, uint24(500), USDT);
        vm.prank(outsider, outsider);
        vm.expectRevert(V3Path.InvalidPath.selector);
        router.buyWithBnb{value: 0.01 ether}(key, wrongEnd, 1, 1, outsider);
        bytes memory truncated = abi.encodePacked(WBNB, uint24(2500));
        vm.prank(outsider, outsider);
        vm.expectRevert(V3Path.InvalidPath.selector);
        router.buyWithBnb{value: 0.01 ether}(key, truncated, 1, 1, outsider);
    }

    function test_router_rejectsUnknownPools() public {
        PoolKey memory bad = key;
        bad.currency0 = Currency.wrap(USDT);
        bad.currency1 = Currency.wrap(WBNB);
        vm.prank(outsider, outsider);
        vm.expectRevert(StockRouter.UnknownPool.selector);
        router.buy(bad, 1, 0, outsider);
    }

    function test_router_sellForBnbToRejectingOrReenteringRecipientReverts() public {
        _afterHoldCap();
        uint256 got = _buy(outsider, _b(0.01 ether));
        RejectingRecipient rej = new RejectingRecipient();
        ReenteringRecipient re = new ReenteringRecipient();
        re.arm(router, key);
        bytes memory sellPath = _sellPath();
        vm.startPrank(outsider, outsider);
        token.approve(address(router), got);
        vm.expectRevert(StockRouter.SendFailed.selector);
        router.sellForBnb(key, got, sellPath, 1, address(rej));
        vm.expectRevert(StockRouter.SendFailed.selector); // the re-entry hits `Reentered`, so the payment fails
        router.sellForBnb(key, got, sellPath, 1, address(re));
        vm.stopPrank();
    }

    function test_router_bnbToBaseFundsAPresale() public {
        bytes memory path = _buyPath();
        vm.prank(creator, creator);
        uint256 out = router.bnbToBase{value: 0.01 ether}(path, base, 1, creator);
        assertGt(out, 0);
        assertEq(IERC20(base).balanceOf(creator), out);
        _assertRouterEmpty();
    }

    function test_router_refusesStrayBnb() public {
        vm.prank(outsider);
        (bool ok,) = address(router).call{value: 1 ether}("");
        assertFalse(ok, "only WBNB unwrapping pays the router");
    }

    // ------------------------------------------------------------------
    // StockFeeSink: platform bStock -> WBNB -> BNB -> SuanBuyBurn -> $SUAN burned
    // ------------------------------------------------------------------

    function test_feeSink_conversionEndsInSuanBurned() public {
        _earnPlatformFees();
        hook.dispatch(address(token));
        uint256 held = IERC20(base).balanceOf(address(sink));
        assertGt(held, 0, "the platform's bStock reached the sink");
        bytes memory path = _sellPath();
        (uint256 quote,,,) = IQuoterV2S(V3_QUOTER).quoteExactInput(path, held);

        uint256 sbbBefore = SUAN_BUY_BURN.balance;
        vm.expectEmit(true, false, false, false, address(sink));
        emit StockFeeSink.Converted(base, held, 0);
        vm.prank(keeper);
        uint256 bnbOut = sink.convert(base, type(uint256).max, path, quote * 99 / 100);
        assertGe(bnbOut, quote * 99 / 100);
        assertEq(SUAN_BUY_BURN.balance - sbbBefore, bnbOut, "all of it to SuanBuyBurn as BNB");
        assertEq(IERC20(base).balanceOf(address(sink)), 0);
        assertEq(address(sink).balance, 0, "the sink keeps nothing");
        assertEq(IERC20(WBNB).balanceOf(address(sink)), 0);
        assertEq(sink.totalBnbSent(), bnbOut);

        uint256 deadBefore = IERC20(SUAN).balanceOf(DEAD);
        vm.prank(ISuanBuyBurnS(SUAN_BUY_BURN).keeper());
        uint256 burned = ISuanBuyBurnS(SUAN_BUY_BURN).buyAndBurn(bnbOut, 1);
        assertGt(burned, 0);
        assertEq(IERC20(SUAN).balanceOf(DEAD) - deadBefore, burned, "$SUAN burned");
    }

    function test_feeSink_convertsViaUsdtAndPartially() public {
        _earnPlatformFees();
        hook.dispatch(address(token));
        uint256 held = IERC20(base).balanceOf(address(sink));
        bytes memory path = abi.encodePacked(base, uint24(2500), USDT, uint24(500), WBNB);
        uint256 sbbBefore = SUAN_BUY_BURN.balance;
        vm.prank(keeper);
        uint256 bnbOut = sink.convert(base, held / 2, path, 1);
        assertGt(bnbOut, 0);
        assertEq(SUAN_BUY_BURN.balance - sbbBefore, bnbOut);
        assertEq(IERC20(base).balanceOf(address(sink)), held - held / 2, "only the asked amount");
    }

    function test_feeSink_keeperOnlyGuardedNoWithdrawal() public {
        _earnPlatformFees();
        hook.dispatch(address(token));
        bytes memory path = _sellPath();
        vm.prank(outsider);
        vm.expectRevert(StockFeeSink.NotKeeper.selector);
        sink.convert(base, type(uint256).max, path, 1);

        vm.prank(keeper);
        vm.expectRevert(); // below the keeper's floor
        sink.convert(base, type(uint256).max, path, type(uint256).max);

        bytes memory toUsdt = abi.encodePacked(base, uint24(2500), USDT);
        vm.prank(keeper);
        vm.expectRevert(V3Path.InvalidPath.selector);
        sink.convert(base, type(uint256).max, toUsdt, 1);

        vm.prank(keeper);
        vm.expectRevert(StockFeeSink.NothingToConvert.selector);
        sink.convert(SPCXB == base ? NVDAB : SPCXB, type(uint256).max, abi.encodePacked(SPCXB == base ? NVDAB : SPCXB, uint24(2500), WBNB), 1);

        vm.prank(outsider);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", outsider));
        sink.setKeeper(outsider);
        vm.expectRevert(StockFeeSink.ZeroAddress.selector);
        sink.setKeeper(address(0));

        vm.prank(outsider);
        (bool ok,) = address(sink).call{value: 1 ether}("");
        assertFalse(ok, "only WBNB pays the sink");
    }

    // ------------------------------------------------------------------
    // a bStock that refuses transfers
    // ------------------------------------------------------------------

    function test_pause_pausedBaseFreezesOnlyItsOwnLaunches() public {
        address otherBase = base == NVDAB ? SPCXB : NVDAB;
        StockLaunchFactory.CreateParams memory p = _params();
        p.base = otherBase;
        StockToken other = _createWith(factory, p, creator);
        PoolKey memory otherKey = hook.poolKeyOf(address(other));
        vm.roll(block.number + 10); // past the other launch's anti-sniper ladder
        _afterHoldCap();
        uint256 got = _buy(outsider, _b(1 ether));
        _tradeOther(otherBase, otherKey, other, 1 ether);
        StockHolderRewards r = token.rewards();
        address holder = _agent();
        _buy(holder, _b(0.05 ether));
        _buy(outsider, _b(0.5 ether)); // pays the holder
        uint256 holderOwed = r.pending(holder);
        assertGt(holderOwed, 0);

        vm.mockCall(PAUSE_MANAGER, abi.encodeCall(IPauseManagerS.isTokenPaused, (base)), abi.encode(true));

        // the paused launch cannot trade, but nothing reverts outside of it
        uint256 amount = _b(0.01 ether);
        vm.startPrank(outsider, outsider);
        IERC20(base).approve(address(router), amount);
        vm.expectRevert();
        router.buy(key, amount, 0, outsider);
        token.approve(address(router), got);
        vm.expectRevert();
        router.sell(key, got, 0, outsider);
        vm.stopPrank();

        (uint256 t0, uint256 f0,,) = hook.owedOf(address(token));
        uint256 s0 = hook.suanOwedOf(address(token));
        uint256 claims0 = VAULT.balanceOf(address(hook), Currency.wrap(base));
        hook.dispatch(address(token)); // does not revert
        (uint256 t1, uint256 f1,,) = hook.owedOf(address(token));
        assertEq(t1, t0, "treasury payout stays owed");
        assertEq(hook.suanOwedOf(address(token)), s0, "fee-sink payout stays owed");
        assertEq(VAULT.balanceOf(address(hook), Currency.wrap(base)), claims0);
        vm.expectRevert(StockCurveHook.FounderTransferFailed.selector);
        hook.claimFounder(address(token));
        assertEq(f1, f0);
        address[] memory batch = new address[](1);
        batch[0] = holder;
        r.claimFor(batch); // does not revert
        assertEq(r.pending(holder), holderOwed, "holder keeps its rewards");

        // the launch on the other bStock keeps trading and paying out
        _tradeOther(otherBase, otherKey, other, 0.5 ether);
        uint256 otherSuan = hook.suanOwedOf(address(other));
        hook.dispatch(address(other));
        assertEq(IERC20(otherBase).balanceOf(address(sink)), otherSuan, "other launch dispatches normally");
        hook.claimFounder(address(other));

        // unpaused: everything owed pays out
        vm.clearMockedCalls();
        hook.dispatch(address(token));
        assertEq(IERC20(base).balanceOf(treasury), t0);
        assertEq(IERC20(base).balanceOf(address(sink)), s0);
        uint256 creatorBefore = IERC20(base).balanceOf(creator);
        hook.claimFounder(address(token));
        assertEq(IERC20(base).balanceOf(creator) - creatorBefore, f0, "founder paid once unpaused");
        r.claimFor(batch);
        assertEq(IERC20(base).balanceOf(holder), holderOwed);
        assertGt(_buy(outsider, amount), 0, "trading again");
    }

    function test_blocklist_blockedFounderOnlyBlocksItself() public {
        address a = _agent();
        _buy(a, _b(0.03 ether));
        vm.mockCallRevert(COMPLIANCE, abi.encodeCall(IComplianceS.checkIsCompliant, (base, creator)), "blocked");
        (uint256 t,,,) = hook.owedOf(address(token));
        vm.expectRevert(StockCurveHook.FounderTransferFailed.selector);
        hook.claimFounder(address(token));
        hook.dispatch(address(token));
        assertEq(IERC20(base).balanceOf(treasury), t, "treasury still paid");
        address b = _agent();
        assertGt(_buy(b, _b(0.01 ether)), 0, "trading unaffected");
    }

    function test_blocklist_blockedHolderKeepsItsRewardsOthersArePaid() public {
        address a = _agent();
        _buy(a, _b(0.03 ether));
        address b = _agent();
        _buy(b, _b(0.03 ether));
        _buy(_agent(), _b(0.03 ether));
        StockHolderRewards r = token.rewards();
        uint256 owedA = r.pending(a);
        uint256 owedB = r.pending(b);
        assertGt(owedA, 0);
        vm.mockCallRevert(COMPLIANCE, abi.encodeCall(IComplianceS.checkIsCompliant, (base, a)), "blocked");
        address[] memory batch = new address[](2);
        batch[0] = a;
        batch[1] = b;
        vm.expectEmit(address(r));
        emit StockHolderRewards.ClaimFailed(a, owedA);
        r.claimFor(batch);
        assertEq(r.pending(a), owedA, "blocked holder keeps its rewards");
        assertEq(IERC20(base).balanceOf(b), owedB, "the rest of the batch is paid");
    }

    // ------------------------------------------------------------------
    // security regressions
    // ------------------------------------------------------------------

    function test_security_reentrantBaseCannotBePaidTwice() public {
        ReentrantBase rb = new ReentrantBase();
        factory.setBase(address(rb), 10_000 ether);
        StockLaunchFactory.CreateParams memory p = _params();
        p.base = address(rb);
        vm.prank(creator, creator);
        StockToken t = factory.create(p);
        PoolKey memory k = hook.poolKeyOf(address(t));
        vm.roll(block.number + 10);
        address a = _agent();
        rb.mint(a, 1_000 ether);
        vm.startPrank(a, a);
        rb.approve(address(router), 1_000 ether);
        router.buy(k, 50 ether, 0, a);
        vm.stopPrank();
        (uint256 tr, uint256 f,,) = hook.owedOf(address(t));
        assertGt(f, 0);
        uint256 claims = VAULT.balanceOf(address(hook), Currency.wrap(address(rb)));

        rb.arm(hook, address(t), false);
        vm.expectRevert(StockCurveHook.FounderTransferFailed.selector);
        hook.claimFounder(address(t));
        rb.arm(hook, address(t), true);
        hook.dispatch(address(t)); // the re-entrant treasury payout fails and stays owed
        (uint256 tr2, uint256 f2,,) = hook.owedOf(address(t));
        assertEq(tr2, tr);
        assertEq(f2, f);
        assertEq(VAULT.balanceOf(address(hook), Currency.wrap(address(rb))), claims, "no claim left the hook");
        assertEq(rb.balanceOf(creator), 0);
        assertEq(rb.balanceOf(treasury), 0);
    }

    function test_security_buybackIsKeeperOnlyAndOncePerBlock() public {
        _openBuybackToken();
        vm.expectRevert(StockCurveHook.NotKeeper.selector);
        hook.buyback(address(token), type(uint256).max, 0);
        factory.setKeeper(keeper);
        vm.prank(keeper);
        (uint256 spent,) = hook.buyback(address(token), _b(0.01 ether), 0);
        assertGt(spent, 0);
        vm.prank(keeper);
        vm.expectRevert(StockCurveHook.BuybackThisBlock.selector);
        hook.buyback(address(token), _b(0.01 ether), 0);
    }

    function test_security_sandwichAroundBuybackIsUnprofitable() public {
        _openBuybackToken();
        factory.setKeeper(keeper);
        uint160 reference_ = _sqrtNow();

        address att = _agent();
        StockBuybackSandwich s = new StockBuybackSandwich();
        uint256 amount = _b(20 ether);
        deal(base, address(s), amount);
        vm.prank(att, att);
        s.run(router, hook, key, IERC20(base), IERC20(address(token)), amount);
        assertLt(IERC20(base).balanceOf(address(s)), amount, "cannot trigger the buyback inside its own transaction");

        address front = _agent();
        uint256 got = _buy(front, amount);
        vm.roll(block.number + 1);
        uint160 bound = _memeIs0() ? uint160(uint256(reference_) * 1005 / 1000) : uint160(uint256(reference_) * 995 / 1000);
        vm.prank(keeper);
        (uint256 spent,) = hook.buyback(address(token), type(uint256).max, bound);
        assertEq(spent, 0, "price past the keeper's bound: nothing bought");
        uint256 back = _sell(front, got);
        assertLt(back, amount, "the front-runner loses its fees");
    }

    function test_security_rewardSnipeIsUnprofitable() public {
        StockLaunchFactory.CreateParams memory p = _params();
        p.buyTaxBps = 300;
        p.sellTaxBps = 300;
        p.agentBuyTaxBps = 0;
        p.agentSellTaxBps = 0;
        p.wFounder = 0;
        p.wHolder = 100;
        p.wBurn = 0;
        p.wLiquidity = 0;
        _useToken(p, _b(0.1 ether));
        _afterHoldCap();
        for (uint256 i; i < 5; ++i) {
            uint256 got = _buy(outsider, _b(10 ether));
            _sell(outsider, got);
        }
        address att = _agent();
        StockRewardSniper s = new StockRewardSniper();
        uint256 amount = _b(20 ether);
        deal(base, address(s), amount);
        vm.prank(att, att);
        s.run(router, hook, key, IERC20(base), token, amount);
        assertLt(IERC20(base).balanceOf(address(s)), amount, "a flash holder earns less than it pays");
    }

    function test_security_onlyFactoryPoolManagerVaultHookToken() public {
        StockCurveHook.LaunchConfig memory c;
        vm.expectRevert(StockCurveHook.OnlyFactory.selector);
        hook.registerLaunch(key, c);
        vm.expectRevert(StockCurveHook.OnlyFactory.selector);
        hook.seed(address(token));
        vm.expectRevert(StockCurveHook.OnlyFactory.selector);
        hook.presale(address(token), outsider, 1);
        vm.expectRevert(StockCurveHook.OnlyFactory.selector);
        hook.setKeeper(outsider);

        ICLPoolManager.SwapParams memory sp =
            ICLPoolManager.SwapParams({zeroForOne: true, amountSpecified: -1, sqrtPriceLimitX96: 0});
        vm.expectRevert(StockCurveHook.OnlyPoolManager.selector);
        hook.beforeSwap(outsider, key, sp, "");
        vm.expectRevert(StockCurveHook.OnlyPoolManager.selector);
        hook.afterSwap(outsider, key, sp, BalanceDelta.wrap(0), "");
        vm.expectRevert(StockCurveHook.OnlyPoolManager.selector);
        hook.beforeInitialize(address(factory), key, 1);

        bytes memory pay = abi.encode(uint8(3), address(token), uint256(1), outsider);
        vm.expectRevert(StockCurveHook.OnlyVault.selector);
        hook.lockAcquired(pay);
        vm.expectRevert(StockRouter.OnlyVault.selector);
        router.lockAcquired("");
        StockHolderRewards r = token.rewards();
        vm.expectRevert(StockHolderRewards.OnlyVault.selector);
        r.lockAcquired(abi.encode(outsider, uint256(1)));
        vm.expectRevert(StockHolderRewards.OnlyHook.selector);
        r.notifyReward(1);
        vm.expectRevert(StockHolderRewards.OnlyToken.selector);
        r.setShare(outsider, 1e30);

        StockTokenDeployer d = factory.tokenDeployer();
        StockToken.Config memory tc;
        vm.expectRevert(StockTokenDeployer.OnlyFactory.selector);
        d.deploy(tc);

        vm.startPrank(outsider);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", outsider));
        factory.setKeeper(outsider);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", outsider));
        factory.setLaunchesOpen(false);
        vm.stopPrank();
    }

    function test_security_claimFounderPaysTheFounderOnce() public {
        (, uint256 owedNow,,) = hook.owedOf(address(token));
        assertGt(owedNow, 0, "presale fees");
        vm.prank(outsider);
        uint256 before = IERC20(base).balanceOf(creator);
        hook.claimFounder(address(token));
        assertEq(IERC20(base).balanceOf(creator) - before, owedNow, "to the founder, whoever triggers it");
        hook.claimFounder(address(token));
        assertEq(IERC20(base).balanceOf(creator) - before, owedNow, "nothing more the second time");
    }

    // ------------------------------------------------------------------
    // helpers
    // ------------------------------------------------------------------

    function _assertRouterEmpty() internal view {
        assertEq(IERC20(base).balanceOf(address(router)), 0, "router keeps no bStock");
        assertEq(IERC20(WBNB).balanceOf(address(router)), 0, "router keeps no WBNB");
        assertEq(address(router).balance, 0, "router keeps no BNB");
        assertEq(token.balanceOf(address(router)), 0, "router keeps no meme");
    }

    function _earnPlatformFees() internal {
        _afterHoldCap();
        for (uint256 i; i < 3; ++i) {
            uint256 got = _buy(outsider, _b(2 ether));
            _sell(outsider, got);
        }
    }

    function _tradeOther(address otherBase, PoolKey memory k, StockToken other, uint256 bnbEq) internal {
        uint256 amount = bnbEq * factory.startAmountOf(otherBase) / BNB_START;
        deal(otherBase, outsider, IERC20(otherBase).balanceOf(outsider) + amount);
        vm.startPrank(outsider, outsider);
        IERC20(otherBase).approve(address(router), amount);
        uint256 got = router.buy(k, amount, 0, outsider);
        other.approve(address(router), got / 2);
        router.sell(k, got / 2, 0, outsider);
        vm.stopPrank();
    }

    function _openBuybackToken() internal {
        StockLaunchFactory.CreateParams memory p = _params();
        p.buyTaxBps = 300;
        p.sellTaxBps = 300;
        p.agentBuyTaxBps = 0;
        p.agentSellTaxBps = 0;
        p.wFounder = 0;
        p.wHolder = 0;
        p.wBurn = 100;
        p.wLiquidity = 0;
        _useToken(p, _b(0.1 ether));
        vm.warp(token.launchTime() + 49 hours);
        for (uint256 i; i < 8; ++i) {
            uint256 got = _buy(outsider, _b(10 ether));
            _sell(outsider, got);
        }
    }
}

contract StockSecurityNvdabTest is StockSecurityTests {
    function _base() internal pure override returns (address) {
        return NVDAB;
    }

    function _memeIs0() internal pure override returns (bool) {
        return false;
    }
}

contract StockSecuritySpcxbTest is StockSecurityTests {
    function _base() internal pure override returns (address) {
        return SPCXB;
    }

    function _memeIs0() internal pure override returns (bool) {
        return true;
    }
}
