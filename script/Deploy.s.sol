// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IVault} from "infinity-core/src/interfaces/IVault.sol";
import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {AgentLaunchFactory} from "../src/AgentLaunchFactory.sol";
import {AgentRouter} from "../src/AgentRouter.sol";
import {SuanBuyBurn} from "../src/SuanBuyBurn.sol";

/// @notice Deploys the $SUAN buy-and-burn sink, the router and the factory (which deploys the hook) on BSC or a BSC fork.
///         The signer comes from the forge CLI (`--account`, `--ledger`, or `--unlocked` on a local fork); this
///         script never reads a key. `TREASURY` is required; `SUAN_BUY_BURN` reuses an existing sink, otherwise one is
///         deployed (owner `OWNER` or the signer, keeper `KEEPER`); `LAUNCH_FEE_WEI` defaults to 0.005 BNB; `KEEPER` sets
///         the buyback keeper (later: `factory.setKeeper`); `OWNER` optionally starts a two-step ownership transfer. The factory deploys closed (only its owner creates)
///         unless `OPEN=true`; later `setLaunchesOpen(true)` or `createAndOpen` (see Launch.s.sol) opens it.
///
///   forge script script/Deploy.s.sol --rpc-url bsc --account <name> --broadcast
contract Deploy is Script {
    IVault constant VAULT = IVault(0x238a358808379702088667322f80aC48bAd5e6c4);
    ICLPoolManager constant CLPM = ICLPoolManager(0xa0FfB9c1CE1Fe56963B0321B32E7A0302114058b);
    address constant AGENT_ID = 0x60B9262456dE011F7d15a54CdD8c48bAaa8B022F;
    /// @dev Uniswap v4 PoolManager on BSC, the other singleton the anti-farm window watches.
    address constant UNI_V4_PM = 0x28e2Ea090877bF75740558f6BFB36A5ffeE9e9dF;
    /// @dev PancakeSwap Universal Router (exposes msgSender()).
    address constant PCS_UR = 0xd9C500DfF816a1Da21A48A732d3498Bf09dc9AEB;
    /// @dev Flap Portal (buys $SUAN on its bonding curve or DEX pool) and $SUAN.
    address constant FLAP_PORTAL = 0xe2cE6ab80874Fa9Fa2aAE65D277Dd6B8e65C9De0;
    address constant SUAN = 0xC561DC47b9c1C036E77EcffDDE66B8f451847777;

    function run() external returns (AgentRouter router, AgentLaunchFactory factory) {
        address treasury = vm.envAddress("TREASURY");
        uint256 launchFee = vm.envOr("LAUNCH_FEE_WEI", uint256(0.005 ether));
        address keeper = vm.envOr("KEEPER", address(0));
        address owner = vm.envOr("OWNER", address(0));
        address sink = vm.envOr("SUAN_BUY_BURN", address(0));
        vm.startBroadcast();
        if (sink == address(0)) {
            sink = address(new SuanBuyBurn(FLAP_PORTAL, SUAN, keeper, owner != address(0) ? owner : msg.sender));
        }
        router = new AgentRouter(VAULT, CLPM);
        address[] memory routers = new address[](2);
        routers[0] = address(router);
        routers[1] = PCS_UR;
        factory = new AgentLaunchFactory(VAULT, CLPM, AGENT_ID, UNI_V4_PM, treasury, sink, routers, launchFee);
        if (keeper != address(0)) factory.setKeeper(keeper);
        // OPEN=true lets anyone create from the start instead of waiting for the owner's first launch
        if (vm.envOr("OPEN", false)) factory.setLaunchesOpen(true);
        // optional: hand the factory to the platform multisig; it takes effect when the multisig calls acceptOwnership
        if (owner != address(0)) factory.transferOwnership(owner);
        vm.stopBroadcast();
        console2.log("DOTAI_SUAN_BUY_BURN", sink);
        console2.log("DOTAI_ROUTER", address(router));
        console2.log("DOTAI_FACTORY", address(factory));
        console2.log("DOTAI_HOOK", address(factory.hook()));
    }
}
