// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "./AgentLaunch.t.sol";

/// @dev Regression tests for the findings of the independent review (the original proofs of concept, turned into
///      "the attack must fail" checks). Fork tests, like AgentLaunch.t.sol.

/// Founder contract that re-enters the hook when paid.
contract ReentrantFounder {
    AgentCurveHook public hook;
    address public token;
    function arm(AgentCurveHook h, address t) external {
        hook = h;
        token = t;
    }
    receive() external payable {
        if (address(hook).balance >= msg.value) {
            hook.dispatch(token);
            hook.claimFounder(token);
        }
    }
}

/// Founder contract that refuses BNB.
contract RejectingFounder {
    receive() external payable {
        revert("no");
    }
}

/// Buys, tries to loop buyback, sells, all in one transaction.
contract BuybackSandwich {
    function run(AgentRouter r, AgentCurveHook h, PoolKey calldata k, IERC20 t) external payable {
        r.buy{value: msg.value}(k, 0, 0, address(this));
        try h.buyback(address(t), type(uint256).max, 0) {} catch {}
        uint256 bal = t.balanceOf(address(this));
        t.approve(address(r), bal);
        r.sell(k, bal, 0, address(this));
        payable(tx.origin).transfer(address(this).balance);
    }
    receive() external payable {}
}

/// Buys, tries to trigger reward payout and claim, sells, all in one transaction.
contract RewardSniper {
    function run(AgentRouter r, AgentCurveHook h, PoolKey calldata k, AgentToken t) external payable {
        r.buy{value: msg.value}(k, 0, 0, address(this));
        h.dispatch(address(t));
        t.rewards().claim();
        uint256 bal = t.balanceOf(address(this));
        t.approve(address(r), bal);
        r.sell(k, bal, 0, address(this));
        payable(tx.origin).transfer(address(this).balance);
    }
    receive() external payable {}
}

contract SecurityTest is AgentLaunchTest {
    address keeper = makeAddr("keeper");

    function _taxed(address founder) internal pure returns (AgentLaunchFactory.CreateParams memory p) {
        p.name = "X";
        p.symbol = "X";
        p.founder = founder;
        p.buyTaxBps = 1000;
        p.sellTaxBps = 1000;
        p.agentBuyTaxBps = 700;
        p.agentSellTaxBps = 700;
        p.wFounder = 100;
        p.minShare = 10_000 ether;
        p.aiOnlySeconds = AI_ONLY;
        p.holdCapSeconds = HOLD_CAP_WINDOW;
        p.taxSeconds = TAX_PERIOD;
    }

    /// C-1: a founder contract cannot re-enter to be paid more than once or drain other launches.
    function test_security_founderReentrancyCannotDrainTheHook() public {
        address victim = makeAddr("victimCreator");
        vm.etch(victim, "");
        vm.deal(victim, 20 ether);
        AgentLaunchFactory.CreateParams memory pv = _taxed(address(0));
        pv.wFounder = 0;
        pv.wBurn = 100;
        vm.prank(victim, victim);
        AgentToken vt = factory.create{value: 0.1 ether}(pv);
        // the victim launch earns: an outsider trades it after the .ai window
        vm.warp(vt.holdCapUntil());
        vm.prank(outsider, outsider);
        router.buy{value: 5 ether}(hook.poolKeyOf(address(vt)), 0, 0, outsider);
        (uint256 t0,,, uint256 b0) = hook.owedOf(address(vt));

        ReentrantFounder evil = new ReentrantFounder();
        address attacker = makeAddr("attackerCreator");
        vm.etch(attacker, "");
        vm.deal(attacker, 2 ether);
        vm.prank(attacker, attacker);
        AgentToken at = factory.create{value: 0.1 ether}(_taxed(address(evil)));
        evil.arm(hook, address(at));
        (, uint256 owedToEvil,,) = hook.owedOf(address(at));

        // the re-entry reverts, so the founder's own claim fails as a whole and nothing leaves the hook
        vm.expectRevert();
        hook.claimFounder(address(at));
        assertEq(address(evil).balance, 0, "re-entrant founder is not paid at all");
        (, uint256 stillOwed,,) = hook.owedOf(address(at));
        assertEq(stillOwed, owedToEvil, "its claim stays owed");
        assertGe(address(hook).balance, t0 + b0, "the victim launch stays covered");
    }

    /// M-2: a founder that refuses BNB cannot block the treasury payout or anything else.
    function test_security_rejectingFounderBlocksOnlyItself() public {
        RejectingFounder bad = new RejectingFounder();
        AgentLaunchFactory.CreateParams memory p = _taxed(address(bad));
        p.wFounder = 50;
        p.wHolder = 50;
        vm.prank(creator, creator);
        AgentToken t = factory.create{value: 0.1 ether}(p);
        (uint256 treasuryOwed,,,) = hook.owedOf(address(t));
        uint256 before = treasury.balance;
        hook.dispatch(address(t));
        assertEq(treasury.balance - before, treasuryOwed, "treasury paid despite the founder");
        vm.expectRevert(AgentCurveHook.FounderTransferFailed.selector);
        hook.claimFounder(address(t));
    }

    /// Founder payout is pull-based and pays exactly what is owed, to the founder only.
    function test_security_claimFounderPaysTheFounderOnce() public {
        (, uint256 owedNow,,) = hook.owedOf(address(token));
        assertGt(owedNow, 0);
        uint256 before = creator.balance;
        vm.prank(outsider);
        hook.claimFounder(address(token)); // anyone may trigger it; the money goes to the founder
        assertEq(creator.balance - before, owedNow);
        hook.claimFounder(address(token));
        assertEq(creator.balance - before, owedNow, "nothing more the second time");
    }

    /// H-1: buyback is keeper-only, once per block, and respects the keeper's price floor.
    function test_security_buybackIsKeeperOnlyAndOncePerBlock() public {
        _openBuybackToken();
        vm.expectRevert(AgentCurveHook.NotKeeper.selector);
        hook.buyback(address(token), type(uint256).max, 0);

        factory.setKeeper(keeper);
        vm.prank(keeper);
        (uint256 spent,) = hook.buyback(address(token), 0.01 ether, 0);
        assertGt(spent, 0);
        vm.prank(keeper);
        vm.expectRevert(AgentCurveHook.BuybackThisBlock.selector);
        hook.buyback(address(token), 0.01 ether, 0);
    }

    function test_security_sandwichAroundBuybackIsUnprofitable() public {
        _openBuybackToken();
        factory.setKeeper(keeper);
        (uint160 reference_,,,) = CLPM.getSlot0(key.toId());

        address att = _agent();
        vm.deal(att, 30 ether);
        BuybackSandwich s = new BuybackSandwich();
        uint256 before = att.balance;
        vm.prank(att, att);
        s.run{value: 20 ether}(router, hook, key, IERC20(address(token)));
        assertLt(att.balance, before, "attacker cannot trigger buyback inside its own transaction");

        // a front-run before the keeper's buyback: the keeper's floor from the earlier price stops it buying high
        address front = _agent();
        vm.deal(front, 30 ether);
        uint256 got = _buy(front, 20 ether);
        vm.roll(block.number + 1);
        vm.prank(keeper);
        (uint256 spent,) = hook.buyback(address(token), type(uint256).max, uint160(uint256(reference_) * 995 / 1000));
        assertEq(spent, 0, "price above the keeper's floor: nothing bought");
        uint256 bnbBefore = front.balance;
        _sell(front, got);
        assertLt(front.balance - bnbBefore, 20 ether, "the front-runner loses its fees");
    }

    /// M-1: holder rewards are deposited with every trade, so a flash position cannot collect them.
    function test_security_rewardSnipeIsUnprofitable() public {
        AgentLaunchFactory.CreateParams memory p = _params();
        p.buyTaxBps = 300;
        p.sellTaxBps = 300;
        p.agentBuyTaxBps = 0;
        p.agentSellTaxBps = 0;
        p.wFounder = 0;
        p.wHolder = 100;
        p.wBurn = 0;
        p.wLiquidity = 0;
        _useToken(p, 0.1 ether);
        _afterHoldCap();
        vm.deal(outsider, 1000 ether);
        for (uint256 i; i < 5; ++i) {
            uint256 got = _buy(outsider, 10 ether);
            _sell(outsider, got);
        }
        (,, uint256 holderOwed,) = hook.owedOf(address(token));
        assertEq(holderOwed, 0, "holder tax is already in HolderRewards, nothing to time");

        address att = _agent();
        vm.deal(att, 30 ether);
        RewardSniper s = new RewardSniper();
        uint256 before = att.balance;
        vm.prank(att, att);
        s.run{value: 20 ether}(router, hook, key, token);
        assertLt(att.balance, before, "flash holder earns less than it pays");
    }

    function _openBuybackToken() internal {
        AgentLaunchFactory.CreateParams memory p = _params();
        p.buyTaxBps = 300;
        p.sellTaxBps = 300;
        p.agentBuyTaxBps = 0;
        p.agentSellTaxBps = 0;
        p.wFounder = 0;
        p.wHolder = 0;
        p.wBurn = 100;
        p.wLiquidity = 0;
        _useToken(p, 0.1 ether);
        vm.warp(token.launchTime() + 49 hours);
        vm.deal(outsider, 1000 ether);
        for (uint256 i; i < 8; ++i) {
            uint256 got = _buy(outsider, 10 ether);
            _sell(outsider, got);
        }
    }
}
