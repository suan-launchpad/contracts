// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {FairMintFactory} from "../../src/fairmint/FairMintFactory.sol";
import {FairMintTaxSink} from "../../src/fairmint/FairMintTaxSink.sol";
import {SuanV2Router} from "../../src/fairmint/SuanV2Router.sol";

/// @notice Deploys the Agent ID fair mint (token version): `FairMintTaxSink`, `FairMintFactory` (which deploys the
///         `FairMintSale` implementation) and `SuanV2Router`. Owners are set in the constructors, so there is no
///         ownership transfer to accept.
///         Required env: `OWNER` (admin), `KEEPER` (sells the tax sink's tokens).
///         Logs `FAIRMINT_FACTORY`, `FAIRMINT_ROUTER`, `FAIRMINT_TAX_SINK`, `FAIRMINT_IMPLEMENTATION`,
///         `FAIRMINT_START_BLOCK`.
///
///   OWNER=0x… KEEPER=0x… forge script script/fairmint/DeployFairMint.s.sol --rpc-url bsc --account <name> --broadcast
contract DeployFairMint is Script {
    address constant SUAN_BUY_BURN = 0xF611041e441CD2037d415cB368d8cB45F31E134A;
    address constant AGENT_ID = 0x60B9262456dE011F7d15a54CdD8c48bAaa8B022F;
    address constant V2_FACTORY = 0xcA143Ce32Fe78f1f7019d7d551a6402fC5350c73;
    address constant V2_ROUTER = 0x10ED43C718714eb63d5aA57B78B54704E256024E;
    address constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    bytes32 constant PAIR_INIT_CODE_HASH = 0x00fb7f630766e6a796048ea87d01acd3068e8ff67d078148a3fa3f4a84f69bd5;

    function run() external returns (FairMintFactory factory, SuanV2Router router, FairMintTaxSink taxSink) {
        address owner_ = vm.envAddress("OWNER");
        address keeper_ = vm.envAddress("KEEPER");

        vm.startBroadcast();
        taxSink = new FairMintTaxSink(V2_ROUTER, SUAN_BUY_BURN, keeper_, owner_);
        factory = new FairMintFactory(
            AGENT_ID, V2_FACTORY, WBNB, PAIR_INIT_CODE_HASH, SUAN_BUY_BURN, address(taxSink), owner_
        );
        router = new SuanV2Router(V2_ROUTER, SUAN_BUY_BURN);
        vm.stopBroadcast();

        console2.log("FAIRMINT_FACTORY", address(factory));
        console2.log("FAIRMINT_ROUTER", address(router));
        console2.log("FAIRMINT_TAX_SINK", address(taxSink));
        console2.log("FAIRMINT_IMPLEMENTATION", factory.implementation());
        console2.log("FAIRMINT_START_BLOCK", block.number);
    }
}
