// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {FairMintFactory} from "../../src/fairmint/FairMintFactory.sol";
import {FairMintERC20} from "../../src/fairmint/FairMintERC20.sol";
import {FairMintSale} from "../../src/fairmint/FairMintSale.sol";
import {FairMintTaxSink} from "../../src/fairmint/FairMintTaxSink.sol";
import {SuanV2Router} from "../../src/fairmint/SuanV2Router.sol";
import {IPancakeV2Factory, IPancakeV2Pair} from "../../src/fairmint/IPancakeV2.sol";

/// @dev Stands in for the soulbound SPACE ID Agent ID: `balanceOf` is all the sale reads.
contract MockAgentId {
    mapping(address => uint256) public balanceOf;

    function give(address to) external {
        balanceOf[to] = 1;
    }
}

contract RejectsBnb {
    receive() external payable {
        revert("no");
    }
}

contract FairMintTest is Test {
    address constant V2_FACTORY = 0xcA143Ce32Fe78f1f7019d7d551a6402fC5350c73;
    address constant V2_ROUTER = 0x10ED43C718714eb63d5aA57B78B54704E256024E;
    address constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;
    bytes32 constant PAIR_INIT = 0x00fb7f630766e6a796048ea87d01acd3068e8ff67d078148a3fa3f4a84f69bd5;

    FairMintFactory factory;
    SuanV2Router router;
    FairMintTaxSink taxSink;
    address keeper = makeAddr("keeper");
    MockAgentId agentId;
    address sink = makeAddr("sink");
    address owner = makeAddr("owner");
    address creator = makeAddr("creator");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");
    address human = makeAddr("human");

    function setUp() public {
        vm.createSelectFork(vm.envOr("BSC_RPC_URL", string("https://bsc-dataseed.bnbchain.org")));
        address[6] memory people = [sink, creator, alice, bob, carol, human];
        for (uint256 i; i < people.length; ++i) {
            vm.etch(people[i], ""); // label-derived addresses can carry EIP-7702 sweeper code on BSC mainnet
            vm.deal(people[i], 100 ether);
        }
        agentId = new MockAgentId();
        agentId.give(alice);
        agentId.give(bob);
        agentId.give(carol);
        taxSink = new FairMintTaxSink(V2_ROUTER, sink, keeper, owner);
        factory = new FairMintFactory(address(agentId), V2_FACTORY, WBNB, PAIR_INIT, sink, address(taxSink), owner);
        router = new SuanV2Router(V2_ROUTER, sink);
    }

    // ------------------------------------------------------------ helpers

    function _params() internal view returns (FairMintSale.Params memory p) {
        FairMintSale.Tier[] memory tiers = new FairMintSale.Tier[](2);
        tiers[0] = FairMintSale.Tier({upTo: 600, price: 0.001 ether});
        tiers[1] = FairMintSale.Tier({upTo: 1_000, price: 0.002 ether});
        p = FairMintSale.Params({
            name: "Fair Agent",
            symbol: "FAIR",
            meta: "bafy-meta",
            tiers: tiers,
            maxShares: 1_000,
            targetShares: 300,
            deadline: uint64(block.timestamp + 1 days),
            perWallet: 100,
            inviteBonus: 0,
            maxInviteBonus: 0,
            creatorBnbBps: 1_000,
            creatorTokenBps: 300,
            vestingSeconds: 30 days,
            tax: FairMintERC20.Tax(0, 0, 0, 0, 0, 0)
        });
    }

    function _create(FairMintSale.Params memory p) internal returns (FairMintSale sale) {
        vm.prank(creator);
        sale = FairMintSale(factory.create{value: 0.06 ether}(p));
    }

    function _mint(FairMintSale sale, address who, uint64 shares) internal returns (uint256 cost) {
        cost = sale.costOf(sale.sold(), shares);
        vm.prank(who);
        sale.mint{value: cost}(shares, address(0));
    }

    /// @dev Mint `total` more shares from fresh agent wallets, 100 each (the per-wallet cap).
    function _fill(FairMintSale sale, uint256 total) internal returns (address first) {
        uint256 n;
        while (total > 0) {
            address a = makeAddr(string(abi.encodePacked("agent", vm.toString(n++), vm.toString(address(sale)))));
            vm.etch(a, "");
            agentId.give(a);
            vm.deal(a, 1_000 ether);
            uint64 shares = uint64(total > 100 ? 100 : total);
            _mint(sale, a, shares);
            if (first == address(0)) first = a;
            total -= shares;
        }
    }

    function _agent(string memory label) internal returns (address a) {
        a = makeAddr(label);
        vm.etch(a, "");
        agentId.give(a);
        vm.deal(a, 100 ether);
    }

    function _people(address a) internal pure returns (address[] memory list) {
        list = new address[](1);
        list[0] = a;
    }

    // ------------------------------------------------------------ creation

    function test_create_chargesFeeAndHoldsBond() public {
        uint256 sinkBefore = sink.balance;
        FairMintSale sale = _create(_params());
        assertEq(sink.balance - sinkBefore, 0.01 ether, "creation fee to sink");
        assertEq(address(sale).balance, 0.05 ether, "bond held by sale");
        assertEq(sale.creator(), creator);
        assertTrue(factory.isSale(address(sale)));
        assertEq(sale.tokensPerShare(), (1_000_000_000 ether - 30_000_000 ether) / 2_000);
    }

    function test_create_rejectsWrongPaymentAndBadParams() public {
        FairMintSale.Params memory p = _params();
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(FairMintFactory.WrongPayment.selector, 0.06 ether));
        factory.create{value: 0.05 ether}(p);

        p.targetShares = 100; // under 20% of max
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(FairMintFactory.BadParams.selector, "targetShares"));
        factory.create{value: 0.06 ether}(p);

        p = _params();
        p.tiers[1].price = 0.0005 ether; // price falls
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(FairMintFactory.BadParams.selector, "tier price"));
        factory.create{value: 0.06 ether}(p);

        p = _params();
        p.creatorBnbBps = 1_600;
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(FairMintFactory.BadParams.selector, "creatorBnbBps"));
        factory.create{value: 0.06 ether}(p);

        p = _params();
        p.deadline = uint64(block.timestamp + 15 days);
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(FairMintFactory.BadParams.selector, "deadline"));
        factory.create{value: 0.06 ether}(p);
    }

    function test_implementationAndClonesCannotBeReinitialized() public {
        FairMintSale sale = _create(_params());
        FairMintSale.Wiring memory w =
            FairMintSale.Wiring(alice, address(agentId), V2_FACTORY, WBNB, alice, alice, PAIR_INIT);
        vm.expectRevert(FairMintSale.AlreadyInitialized.selector);
        sale.initialize(_params(), w);
        FairMintSale impl = FairMintSale(factory.implementation());
        vm.expectRevert(FairMintSale.AlreadyInitialized.selector);
        impl.initialize(_params(), w);
    }

    function test_ownerOnlyTouchesFutureSales() public {
        FairMintSale sale = _create(_params());
        vm.startPrank(owner);
        factory.setBond(0.2 ether);
        factory.setCreationFee(0.02 ether);
        vm.expectRevert(FairMintFactory.FeeTooHigh.selector);
        factory.setBond(0.6 ether);
        factory.setOpen(false);
        vm.stopPrank();
        assertEq(sale.bond(), 0.05 ether, "existing sale keeps its bond");
        vm.prank(creator);
        vm.expectRevert(FairMintFactory.Closed.selector);
        factory.create{value: 0.22 ether}(_params());
        // an existing sale keeps minting while creation is closed
        _mint(sale, alice, 10);
        assertEq(sale.sold(), 10);
    }

    // ------------------------------------------------------------ minting

    function test_mint_onlyAgentIdHolders() public {
        FairMintSale sale = _create(_params());
        vm.prank(human);
        vm.expectRevert(FairMintSale.NotAgent.selector);
        sale.mint{value: 0.001 ether}(1, address(0));
    }

    function test_mint_pricesAcrossTiersAndReturnsExcess() public {
        FairMintSale sale = _create(_params());
        _fill(sale, 550);
        uint256 cost = sale.costOf(550, 100);
        assertEq(cost, 50 * 0.001 ether + 50 * 0.002 ether, "crosses the tier boundary");
        uint256 before = bob.balance;
        vm.prank(bob);
        sale.mint{value: cost + 1 ether}(100, address(0));
        assertEq(before - bob.balance, cost, "excess returned");
        assertEq(sale.paidOf(bob), cost);
        assertEq(sale.priceAt(700), 0.002 ether);
    }

    function test_mint_underpaidReverts() public {
        FairMintSale sale = _create(_params());
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(FairMintSale.Underpaid.selector, 0.01 ether));
        sale.mint{value: 0.009 ether}(10, address(0));
    }

    function test_mint_walletCapAndInviteBonus() public {
        FairMintSale.Params memory p = _params();
        p.perWallet = 10;
        p.inviteBonus = 3;
        p.maxInviteBonus = 4;
        FairMintSale sale = _create(p);
        _mint(sale, alice, 10);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(FairMintSale.OverWalletCap.selector, 10));
        sale.mint{value: 0.001 ether}(1, address(0));

        vm.prank(bob);
        sale.mint{value: 0.001 ether}(1, alice); // bob's first mint credits alice
        vm.prank(carol);
        sale.mint{value: 0.001 ether}(1, alice);
        assertEq(sale.walletCap(alice), 14, "bonus 6 earned, capped at 4");
        vm.prank(bob);
        sale.mint{value: 0.001 ether}(1, carol); // not bob's first mint: no credit
        assertEq(sale.inviteBonusOf(carol), 0);
        vm.prank(carol);
        sale.mint{value: 0.001 ether}(1, carol); // self referral never counts
        assertEq(sale.inviteBonusOf(carol), 0);
    }

    function test_mint_closedAfterDeadlineAndWhenSoldOut() public {
        FairMintSale sale = _create(_params());
        _fill(sale, 1_000);
        vm.prank(carol);
        vm.expectRevert(FairMintSale.SoldOut.selector);
        sale.mint{value: 1 ether}(1, address(0));

        FairMintSale other = _create(_params());
        vm.warp(block.timestamp + 1 days);
        vm.prank(alice);
        vm.expectRevert(FairMintSale.MintClosed.selector);
        other.mint{value: 1 ether}(1, address(0));
    }

    // ------------------------------------------------------------ launch

    function test_launch_onSellOut_opensV2PoolAtLastPriceAndBurnsLp() public {
        FairMintSale sale = _create(_params());
        _fill(sale, 1_000);
        uint256 raised = sale.raised();
        assertEq(raised, 600 * 0.001 ether + 400 * 0.002 ether);
        uint256 sinkBefore = sink.balance;

        sale.finalize();
        assertEq(uint256(sale.state()), uint256(FairMintSale.State.Live));
        assertEq(sink.balance - sinkBefore, raised * 200 / 10_000, "2% platform fee");

        IPancakeV2Pair pair = IPancakeV2Pair(sale.pair());
        assertEq(IPancakeV2Factory(V2_FACTORY).getPair(sale.token(), WBNB), address(pair));
        assertGt(IERC20(address(pair)).balanceOf(DEAD), 0, "LP burned");
        assertEq(IERC20(address(pair)).balanceOf(address(sale)), 0, "sale keeps no LP");

        (uint112 r0, uint112 r1,) = pair.getReserves();
        (uint256 bnbReserve, uint256 tokenReserve) = pair.token0() == WBNB ? (uint256(r0), uint256(r1)) : (uint256(r1), uint256(r0));
        uint256 lpBnb = raised - raised * 200 / 10_000 - raised * 1_000 / 10_000;
        assertEq(bnbReserve, lpBnb, "all pool BNB paired");
        // opening price per share = last tier price (rounding can only push it up)
        uint256 perShare = bnbReserve * sale.tokensPerShare() / tokenReserve;
        assertApproxEqAbs(perShare, 0.002 ether, 1e6);
        assertGe(perShare + 1, 0.002 ether);

        // every share is backed: holders + pool + creator never exceed the supply
        IERC20 token = IERC20(sale.token());
        assertLe(token.totalSupply(), 1_000_000_000 ether);
        assertEq(
            token.balanceOf(address(sale)), uint256(1_000) * sale.tokensPerShare() + sale.creatorTokens(), "rest held"
        );
    }

    function test_launch_atDeadlineWhenTargetMet_andClaims() public {
        FairMintSale sale = _create(_params());
        _mint(sale, alice, 100);
        _mint(sale, bob, 100);
        _mint(sale, _agent("dave"), 100);
        vm.expectRevert(FairMintSale.NotYet.selector);
        sale.finalize();
        vm.warp(sale.deadline());
        sale.finalize();
        assertEq(uint256(sale.state()), uint256(FairMintSale.State.Live));

        address[] memory users = new address[](3);
        users[0] = alice;
        users[1] = bob;
        users[2] = carol; // never minted: skipped
        sale.claim(users);
        IERC20 token = IERC20(sale.token());
        assertEq(token.balanceOf(alice), 100 * sale.tokensPerShare());
        assertEq(token.balanceOf(bob), 100 * sale.tokensPerShare());
        assertEq(token.balanceOf(carol), 0);
        sale.claim(users); // second call pays nothing more
        assertEq(token.balanceOf(alice), 100 * sale.tokensPerShare());

        vm.expectRevert(FairMintSale.WrongState.selector);
        vm.prank(alice);
        sale.refund();
    }

    function test_creator_vestsLinearlyAndGetsBondBack() public {
        FairMintSale sale = _create(_params());
        _fill(sale, 1_000);
        sale.finalize();
        uint256 creatorBnb = sale.creatorBnb();
        uint256 creatorTokens = sale.creatorTokens();
        IERC20 token = IERC20(sale.token());

        uint256 before = creator.balance;
        sale.payCreator(); // at launch: bond only
        assertEq(creator.balance - before, 0.05 ether, "bond returned");
        assertEq(token.balanceOf(creator), 0);

        vm.warp(block.timestamp + 15 days);
        before = creator.balance;
        sale.payCreator();
        assertEq(creator.balance - before, creatorBnb / 2);
        assertEq(token.balanceOf(creator), creatorTokens / 2);

        vm.warp(block.timestamp + 30 days);
        sale.payCreator();
        assertEq(token.balanceOf(creator), creatorTokens);
        assertEq(sale.creatorBnbPaid(), creatorBnb);
        vm.expectRevert(FairMintSale.NothingToClaim.selector);
        sale.payCreator();
    }

    function test_launch_survivesAPairCreatedEarlyWithDonations() public {
        FairMintSale sale = _create(_params());
        _fill(sale, 1_000);
        // the token address is predictable; someone creates its pair and donates WBNB before launch
        address predicted = vm.computeCreateAddress(address(sale), vm.getNonce(address(sale)));
        address pair = IPancakeV2Factory(V2_FACTORY).createPair(predicted, WBNB);
        vm.deal(address(this), 1 ether);
        (bool ok,) = WBNB.call{value: 1 ether}(abi.encodeWithSignature("deposit()"));
        assertTrue(ok);
        IERC20(WBNB).transfer(pair, 1 ether);

        sale.finalize();
        assertEq(sale.pair(), pair);
        (uint112 r0, uint112 r1,) = IPancakeV2Pair(pair).getReserves();
        uint256 bnbReserve = IPancakeV2Pair(pair).token0() == WBNB ? r0 : r1;
        uint256 raised = sale.raised();
        assertEq(bnbReserve, raised - raised * 200 / 10_000 - raised * 1_000 / 10_000, "donation skimmed away");
    }

    // ------------------------------------------------------------ failure

    function test_fail_refundsEveryoneInFullAndForfeitsBond() public {
        FairMintSale sale = _create(_params());
        uint256 aliceCost = _mint(sale, alice, 100);
        uint256 bobCost = _mint(sale, bob, 50);
        vm.warp(sale.deadline());
        uint256 sinkBefore = sink.balance;
        sale.finalize();
        assertEq(uint256(sale.state()), uint256(FairMintSale.State.Failed));
        assertEq(sink.balance - sinkBefore, 0.05 ether, "bond forfeited to sink");

        uint256 before = alice.balance;
        vm.prank(alice);
        sale.refund();
        assertEq(alice.balance - before, aliceCost);
        before = bob.balance;
        vm.prank(bob);
        sale.refund();
        assertEq(bob.balance - before, bobCost);
        assertEq(address(sale).balance, 0, "nothing left behind");

        vm.prank(alice);
        vm.expectRevert(FairMintSale.NothingToClaim.selector);
        sale.refund();
        vm.expectRevert(FairMintSale.WrongState.selector);
        sale.claim(_people(alice));
        vm.expectRevert(FairMintSale.WrongState.selector);
        sale.payCreator();
    }

    function test_fail_feeTransferFailureIsOwedNotBlocking() public {
        RejectsBnb badSink = new RejectsBnb();
        FairMintFactory f =
            new FairMintFactory(address(agentId), V2_FACTORY, WBNB, PAIR_INIT, address(badSink), address(taxSink), owner);
        vm.prank(owner);
        f.setCreationFee(0);
        vm.prank(creator);
        FairMintSale sale = FairMintSale(f.create{value: 0.05 ether}(_params()));
        _mint(sale, alice, 10);
        vm.warp(sale.deadline());
        sale.finalize(); // bond cannot reach the sink, but the sale still fails and refunds work
        assertEq(sale.feeOwed(), 0.05 ether);
        vm.prank(alice);
        sale.refund();
        assertEq(address(sale).balance, 0.05 ether, "only the owed bond remains");
    }

    // ------------------------------------------------------------ router

    function test_router_buyAndSellTakeOnePercentToSink() public {
        FairMintSale sale = _create(_params());
        _fill(sale, 1_000);
        sale.finalize();
        address token = sale.token();

        uint256 sinkBefore = sink.balance;
        vm.prank(carol);
        uint256 got = router.buy{value: 0.1 ether}(token, 1, carol, block.timestamp);
        assertEq(sink.balance - sinkBefore, 0.001 ether, "1% of the buy");
        assertEq(IERC20(token).balanceOf(carol), got);

        sinkBefore = sink.balance;
        uint256 bnbBefore = carol.balance;
        vm.startPrank(carol);
        IERC20(token).approve(address(router), got);
        uint256 out = router.sell(token, got, 1, carol, block.timestamp);
        vm.stopPrank();
        uint256 fee = sink.balance - sinkBefore;
        assertEq(carol.balance - bnbBefore, out);
        assertEq(fee, (out + fee) / 100, "1% of the sell proceeds");
        assertEq(address(router).balance, 0, "router keeps nothing");
        assertEq(IERC20(token).balanceOf(address(router)), 0);
    }

    function test_router_sellRespectsMinimum() public {
        FairMintSale sale = _create(_params());
        address seller = _fill(sale, 1_000);
        sale.finalize();
        sale.claim(_people(seller));
        address token = sale.token();
        uint256 amount = IERC20(token).balanceOf(seller) / 100;
        vm.startPrank(seller);
        IERC20(token).approve(address(router), amount);
        vm.expectRevert();
        router.sell(token, amount, 100 ether, seller, block.timestamp);
        vm.stopPrank();
    }

    function test_router_rejectsStrayBnb() public {
        vm.expectRevert(SuanV2Router.NotRouter.selector);
        (bool ok,) = address(router).call{value: 1}("");
        ok;
    }

    // ------------------------------------------------------------ fuzz

    /// @dev For any mint pattern that reaches the target: the token fits the supply, the pool opens no lower than the
    ///      last share's price, and every wei raised is accounted for.
    function testFuzz_launchAccounting(uint16 total, uint128 p1, uint128 p2) public {
        FairMintSale.Params memory p = _params();
        p1 = uint128(bound(p1, 1e12, 1 ether));
        p2 = uint128(bound(p2, p1, 2 ether));
        p.tiers[0].price = p1;
        p.tiers[1].price = p2;
        FairMintSale sale = _create(p);
        _fill(sale, bound(total, 1, 1_000));
        vm.warp(sale.deadline());
        uint256 raised = sale.raised();
        uint64 sold = sale.sold();
        sale.finalize();
        if (sold < p.targetShares) {
            assertEq(uint256(sale.state()), uint256(FairMintSale.State.Failed));
            return;
        }
        IERC20 token = IERC20(sale.token());
        assertLe(token.totalSupply(), 1_000_000_000 ether);
        (uint112 r0, uint112 r1,) = IPancakeV2Pair(sale.pair()).getReserves();
        (uint256 bnbReserve, uint256 tokenReserve) =
            IPancakeV2Pair(sale.pair()).token0() == WBNB ? (uint256(r0), uint256(r1)) : (uint256(r1), uint256(r0));
        uint256 fee = raised * 200 / 10_000;
        assertEq(bnbReserve + fee + sale.creatorBnb(), raised, "raised fully split");
        // pool price per share >= last share price (cross-multiplied to avoid rounding loss)
        assertGe(bnbReserve * sale.tokensPerShare(), uint256(sale.priceAt(sold)) * tokenReserve);
        assertEq(address(sale).balance, sale.creatorBnb() + sale.bond(), "only creator share and bond remain");
    }

    // ------------------------------------------------------------ token tax

    function _taxed() internal returns (FairMintSale sale, FairMintERC20 token) {
        FairMintSale.Params memory p = _params();
        p.tax = FairMintERC20.Tax({
            buyBps: 300, sellBps: 500, agentBuyBps: 100, agentSellBps: 200, burnShareBps: 5_000, duration: 10 days
        });
        sale = _create(p);
        _fill(sale, 1_000);
        sale.finalize();
        token = FairMintERC20(sale.token());
    }

    function test_tax_pairIsDerivedCorrectly() public {
        (FairMintSale sale, FairMintERC20 token) = _taxed();
        assertEq(token.pair(), sale.pair());
        assertEq(token.taxEndsAt(), block.timestamp + 10 days);
    }

    function test_tax_buySplitsPlatformBurnAndCreator() public {
        (, FairMintERC20 token) = _taxed();
        uint256 creatorBefore = token.balanceOf(creator);
        uint256 deadBefore = token.balanceOf(DEAD);
        vm.prank(human); // not an agent: full 3% buy tax
        router.buy{value: 0.1 ether}(address(token), 1, human, block.timestamp);
        uint256 got = token.balanceOf(human);
        uint256 gross = got * 10_000 / 9_700;
        uint256 tax = gross - got;
        assertApproxEqRel(token.balanceOf(address(taxSink)), tax / 10, 1e14, "10% of tax to the sink");
        assertApproxEqRel(token.balanceOf(DEAD) - deadBefore, (tax - tax / 10) / 2, 1e14, "half of the rest burned");
        assertApproxEqRel(token.balanceOf(creator) - creatorBefore, (tax - tax / 10) / 2, 1e14, "half of the rest to creator");
    }

    function test_tax_agentsPayTheLowerRate() public {
        (FairMintSale sale, FairMintERC20 token) = _taxed();
        assertEq(token.taxBpsOf(sale.pair(), alice), 100, "agent buy");
        assertEq(token.taxBpsOf(sale.pair(), human), 300, "normal buy");
        assertEq(token.taxBpsOf(alice, sale.pair()), 200, "agent sell");
        assertEq(token.taxBpsOf(human, sale.pair()), 500, "normal sell");
        assertEq(token.taxBpsOf(alice, human), 0, "wallet transfers never taxed");
    }

    function test_tax_routerSellKeepsTheSellersAgentRate() public {
        (FairMintSale sale, FairMintERC20 token) = _taxed();
        address seller = makeAddr("agent0");
        // sale fills from agent wallets named agent<n><sale>; pick the first by re-deriving its name
        seller = makeAddr(string(abi.encodePacked("agent", vm.toString(uint256(0)), vm.toString(address(sale)))));
        sale.claim(_people(seller));
        uint256 amount = token.balanceOf(seller) / 10;
        uint256 sinkTokens = token.balanceOf(address(taxSink));
        vm.startPrank(seller);
        token.approve(address(router), amount);
        router.sell(address(token), amount, 1, seller, block.timestamp);
        vm.stopPrank();
        uint256 tax = amount * 200 / 10_000; // agent sell rate, not the 5% normal rate
        assertEq(token.balanceOf(address(taxSink)) - sinkTokens, tax / 10);
    }

    function test_tax_endsAfterTheDuration() public {
        (FairMintSale sale, FairMintERC20 token) = _taxed();
        vm.warp(block.timestamp + 10 days);
        assertEq(token.taxBpsOf(sale.pair(), human), 0);
        assertEq(token.taxBpsOf(human, sale.pair()), 0);
    }

    function test_taxSink_convertsToBnbForSuanBuyBurn() public {
        (, FairMintERC20 token) = _taxed();
        vm.prank(human);
        router.buy{value: 1 ether}(address(token), 1, human, block.timestamp);
        uint256 held = token.balanceOf(address(taxSink));
        assertGt(held, 0);
        vm.expectRevert(FairMintTaxSink.NotKeeper.selector);
        taxSink.convert(address(token), held, 1, block.timestamp);
        uint256 sinkBefore = sink.balance;
        vm.prank(keeper);
        taxSink.convert(address(token), held, 1, block.timestamp);
        assertGt(sink.balance - sinkBefore, 0, "BNB reached SuanBuyBurn");
        assertEq(token.balanceOf(address(taxSink)), 0, "sold without paying tax on itself");
    }

    function test_tax_validation() public {
        FairMintSale.Params memory p = _params();
        p.tax = FairMintERC20.Tax(600, 0, 0, 0, 0, 10 days);
        vm.expectRevert(abi.encodeWithSelector(FairMintFactory.BadParams.selector, "tax"));
        factory.validate(p);
        p.tax = FairMintERC20.Tax(300, 300, 400, 0, 0, 10 days);
        vm.expectRevert(abi.encodeWithSelector(FairMintFactory.BadParams.selector, "agent tax"));
        factory.validate(p);
        p.tax = FairMintERC20.Tax(300, 300, 0, 0, 0, 1 hours);
        vm.expectRevert(abi.encodeWithSelector(FairMintFactory.BadParams.selector, "taxDuration"));
        factory.validate(p);
        p.tax = FairMintERC20.Tax(300, 300, 0, 0, 0, type(uint32).max);
        factory.validate(p); // permanent is allowed
        p.tax = FairMintERC20.Tax(0, 0, 0, 0, 0, 10 days);
        vm.expectRevert(abi.encodeWithSelector(FairMintFactory.BadParams.selector, "taxDuration"));
        factory.validate(p);
    }
}
