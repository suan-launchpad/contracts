// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {SuanBuyBurn} from "../src/SuanBuyBurn.sol";

/// Buys real $SUAN through the real Flap Portal on a BSC fork.
contract SuanBuyBurnTest is Test {
    address constant FLAP_PORTAL = 0xe2cE6ab80874Fa9Fa2aAE65D277Dd6B8e65C9De0;
    IERC20 constant SUAN = IERC20(0xC561DC47b9c1C036E77EcffDDE66B8f451847777);
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;

    SuanBuyBurn sink;
    address keeper = makeAddr("keeper");
    address owner = makeAddr("owner");
    address outsider = makeAddr("outsider");

    function setUp() public {
        vm.createSelectFork(vm.envOr("BSC_RPC_URL", string("https://bsc-dataseed.bnbchain.org")));
        vm.etch(keeper, "");
        vm.etch(owner, "");
        vm.etch(outsider, "");
        sink = new SuanBuyBurn(FLAP_PORTAL, address(SUAN), keeper, owner);
        vm.deal(outsider, 1 ether);
        vm.prank(outsider);
        (bool ok,) = address(sink).call{value: 0.05 ether}("");
        assertTrue(ok, "accepts BNB from anyone");
    }

    function test_buyAndBurn_sendsAllBoughtSuanToDead() public {
        uint256 deadBefore = SUAN.balanceOf(DEAD);
        vm.prank(keeper);
        uint256 burned = sink.buyAndBurn(type(uint256).max, 1);
        assertGt(burned, 0);
        assertEq(SUAN.balanceOf(DEAD) - deadBefore, burned, "dead address received the burn");
        assertEq(SUAN.balanceOf(address(sink)), 0, "keeps no $SUAN");
        assertEq(address(sink).balance, 0, "spent every BNB");
        assertEq(sink.totalBnbSpent(), 0.05 ether);
        assertEq(sink.totalSuanBurned(), burned);
    }

    function test_buyAndBurn_spendsAtMostMaxBnb() public {
        vm.prank(keeper);
        sink.buyAndBurn(0.01 ether, 1);
        assertEq(address(sink).balance, 0.04 ether);
    }

    function test_buyAndBurn_onlyKeeper() public {
        vm.prank(outsider);
        vm.expectRevert(SuanBuyBurn.NotKeeper.selector);
        sink.buyAndBurn(type(uint256).max, 1);
    }

    function test_buyAndBurn_revertsBelowTheKeepersFloor() public {
        vm.prank(keeper);
        vm.expectRevert();
        sink.buyAndBurn(type(uint256).max, type(uint256).max);
        assertEq(address(sink).balance, 0.05 ether, "nothing spent");
    }

    function test_buyAndBurn_revertsWhenEmpty() public {
        vm.prank(keeper);
        sink.buyAndBurn(type(uint256).max, 1);
        vm.prank(keeper);
        vm.expectRevert(SuanBuyBurn.NothingToSpend.selector);
        sink.buyAndBurn(type(uint256).max, 1);
    }

    function test_setKeeper_onlyOwner() public {
        vm.prank(outsider);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, outsider));
        sink.setKeeper(outsider);
        vm.prank(owner);
        sink.setKeeper(outsider);
        assertEq(sink.keeper(), outsider);
    }
}
