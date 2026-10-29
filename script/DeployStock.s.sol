// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IVault} from "infinity-core/src/interfaces/IVault.sol";
import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {StockLaunchFactory} from "../src/StockLaunchFactory.sol";
import {StockRouter} from "../src/StockRouter.sol";
import {StockFeeSink} from "../src/StockFeeSink.sol";

/// @notice Deploys the stock-meme launchpad next to the live BNB launchpad: the router, the fee sink and the factory
///         (which deploys the hook and the token deployer), then allowlists the first eight bStocks with their start
///         amounts. The BNB launchpad contracts are not touched.
///         The signer comes from the forge CLI (`--account`, `--ledger`, or `--unlocked` on a local fork); this script
///         never reads a key.
///         Env: `TREASURY` (required); `SUAN_BUY_BURN` (default the live sink `0xF611…E134A`); `KEEPER` (buyback keeper
///         and fee-sink converter, default the signer); `OWNER` (fee-sink owner, and a two-step ownership transfer of
///         the factory, accepted later by the owner); `LAUNCH_FEE_WEI` (default 0.005 BNB); `OPEN` (default true:
///         anyone may create right away; `OPEN=false` keeps creation to the owner until `setLaunchesOpen(true)`);
///         `SKIP_BASES=true` deploys without the first allowlist (add bases with StockBase.s.sol).
///
///   forge script script/DeployStock.s.sol --rpc-url bsc --account <name> --broadcast
contract DeployStock is Script {
    IVault constant VAULT = IVault(0x238a358808379702088667322f80aC48bAd5e6c4);
    ICLPoolManager constant CLPM = ICLPoolManager(0xa0FfB9c1CE1Fe56963B0321B32E7A0302114058b);
    address constant AGENT_ID = 0x60B9262456dE011F7d15a54CdD8c48bAaa8B022F;
    /// @dev Uniswap v4 PoolManager on BSC, the other singleton the tax period watches.
    address constant UNI_V4_PM = 0x28e2Ea090877bF75740558f6BFB36A5ffeE9e9dF;
    /// @dev PancakeSwap Universal Router (exposes msgSender()).
    address constant PCS_UR = 0xd9C500DfF816a1Da21A48A732d3498Bf09dc9AEB;
    /// @dev PancakeSwap V3 SwapRouter: BNB <-> bStock legs of the router and the fee sink's conversions.
    address constant V3_ROUTER = 0x1b81D678ffb9C0263b24A97847620C99d213eB14;
    address constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    /// @dev The live SuanBuyBurn the BNB launchpad already pays.
    address constant LIVE_SUAN_BUY_BURN = 0xF611041e441CD2037d415cB368d8cB45F31E134A;

    struct Base {
        string symbol;
        address token;
        uint256 startAmount;
    }

    /// @notice The first eight bases: start amounts in raw bStock units (18 decimals) for about a $3K market cap at
    ///         the launch price, like BNB launches.
    function firstBases() public pure returns (Base[] memory b) {
        b = new Base[](8);
        b[0] = Base("NVDAB", 0x02Fca66C1D1aFB4E2A7884261eB00F63598a7436, 14.7 ether);
        b[1] = Base("SPCXB", 0xbe9D156892E55e7154BcD3cB0FEA677F9D3103E1, 22 ether);
        b[2] = Base("BNCB", 0x4902C5ebc598265Ed2212b559B042De8a5Eeec3f, 572 ether);
        b[3] = Base("TSLAB", 0x5b1910eAaD6450E50f816082Aa078C41F10C292f, 7.9 ether);
        b[4] = Base("QQQB", 0x205812CdBed920aFf76C6580abD681a46D11efc7, 4.4 ether);
        b[5] = Base("SKHYB", 0xCA750eF65f295BBECd685Abf54e82CAf297BDB61, 19.6 ether);
        b[6] = Base("AAPLB", 0x431a3BEE82E2ca41e49895CbECE5bB0F76A89b7A, 9.1 ether);
        b[7] = Base("CRCLB", 0x80f3D493EBCe97e343c53D29a137942416B4ffC0, 39.8 ether);
    }

    function run() external returns (StockRouter router, StockFeeSink feeSink, StockLaunchFactory factory) {
        address treasury = vm.envAddress("TREASURY");
        address suanBuyBurn = vm.envOr("SUAN_BUY_BURN", LIVE_SUAN_BUY_BURN);
        uint256 launchFee = vm.envOr("LAUNCH_FEE_WEI", uint256(0.005 ether));
        address owner = vm.envOr("OWNER", address(0));
        vm.startBroadcast();
        address keeper = vm.envOr("KEEPER", msg.sender);
        router = new StockRouter(VAULT, CLPM, V3_ROUTER, WBNB);
        feeSink = new StockFeeSink(WBNB, suanBuyBurn, V3_ROUTER, keeper, owner != address(0) ? owner : msg.sender);
        address[] memory routers = new address[](2);
        routers[0] = address(router);
        routers[1] = PCS_UR;
        factory = new StockLaunchFactory(
            VAULT, CLPM, AGENT_ID, UNI_V4_PM, treasury, address(feeSink), suanBuyBurn, routers, launchFee
        );
        factory.setKeeper(keeper);
        if (!vm.envOr("SKIP_BASES", false)) {
            Base[] memory bases = firstBases();
            for (uint256 i; i < bases.length; ++i) {
                factory.setBase(bases[i].token, bases[i].startAmount);
            }
        }
        if (vm.envOr("OPEN", true)) factory.setLaunchesOpen(true);
        // optional: hand the factory to the platform wallet; it takes effect when that wallet calls acceptOwnership
        if (owner != address(0)) factory.transferOwnership(owner);
        vm.stopBroadcast();
        console2.log("DOTAI_STOCK_ROUTER", address(router));
        console2.log("DOTAI_STOCK_FEE_SINK", address(feeSink));
        console2.log("DOTAI_STOCK_FACTORY", address(factory));
        console2.log("DOTAI_STOCK_HOOK", address(factory.hook()));
        console2.log("DOTAI_STOCK_TOKEN_DEPLOYER", address(factory.tokenDeployer()));
        console2.log("DOTAI_STOCK_START_BLOCK", block.number);
    }
}
