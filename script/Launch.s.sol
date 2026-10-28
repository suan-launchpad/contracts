// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {AgentLaunchFactory} from "../src/AgentLaunchFactory.sol";
import {AgentToken} from "../src/AgentToken.sol";

/// @notice Launches one token through an existing factory. Parameters come from the environment; unset ones take
///         the defaults below (.ai rate 0 and normal rate 3% — the normal rate is always .ai + 3 — split 40/30/20/10, 2-minute .ai window, 1-hour 1% cap,
///         15-day tax period). PERMANENT_TAX=true keeps the .ai discount and the own-pool rule forever.
///
///   FACTORY=0x… NAME="My Agent" SYMBOL=MAG PRESALE_WEI=0 \   (the factory's launch fee is added on top)
///   forge script script/Launch.s.sol --rpc-url bsc --account <name> --broadcast
contract Launch is Script {
    function run() external returns (AgentToken token) {
        AgentLaunchFactory factory = AgentLaunchFactory(vm.envAddress("FACTORY"));
        AgentLaunchFactory.CreateParams memory p;
        p.name = vm.envString("NAME");
        p.symbol = vm.envString("SYMBOL");
        p.meta = vm.envOr("META", string(""));
        p.founder = vm.envOr("FOUNDER", address(0));
        p.agentBuyTaxBps = uint16(vm.envOr("AGENT_BUY_TAX_BPS", uint256(0)));
        p.agentSellTaxBps = uint16(vm.envOr("AGENT_SELL_TAX_BPS", uint256(0)));
        p.buyTaxBps = factory.normalRate(p.agentBuyTaxBps);
        p.sellTaxBps = factory.normalRate(p.agentSellTaxBps);
        p.wFounder = uint8(vm.envOr("W_FOUNDER", uint256(40)));
        p.wHolder = uint8(vm.envOr("W_HOLDER", uint256(30)));
        p.wBurn = uint8(vm.envOr("W_BURN", uint256(20)));
        p.wLiquidity = uint8(vm.envOr("W_LIQUIDITY", uint256(10)));
        p.minShare = vm.envOr("MIN_SHARE_WEI", uint256(10_000 ether));
        p.agentOnlyRewards = vm.envOr("AGENT_ONLY_REWARDS", false);
        p.antiSniper = vm.envOr("ANTI_SNIPER", true);
        p.aiOnlySeconds = uint64(vm.envOr("AI_ONLY_SECONDS", uint256(2 minutes)));
        p.holdCapSeconds = uint64(vm.envOr("HOLD_CAP_SECONDS", uint256(1 hours)));
        p.taxSeconds = vm.envOr("PERMANENT_TAX", false) ? type(uint64).max : uint64(vm.envOr("TAX_SECONDS", uint256(15 days)));
        uint256 presale = vm.envOr("PRESALE_WEI", uint256(0));

        vm.startBroadcast();
        // OPEN=1 (owner only): the platform's first launch, opening creation to everyone in the same transaction
        token = vm.envOr("OPEN", false)
            ? factory.createAndOpen{value: factory.launchFee() + presale}(p)
            : factory.create{value: factory.launchFee() + presale}(p);
        vm.stopBroadcast();
        console2.log("DOTAI_TOKEN", address(token));
    }
}
