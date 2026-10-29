// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {StockLaunchFactory} from "../src/StockLaunchFactory.sol";

interface IERC20Symbol {
    function symbol() external view returns (string memory);
    function decimals() external view returns (uint8);
}

/// @notice Add a bStock to the stock-meme allowlist, change its start amount, or remove it (the "add a stock"
///         command). Only affects new launches; existing launches keep their price and keep trading. The factory owner
///         signs (`--account`, `--ledger`, or `--unlocked --sender <owner>` on a local fork).
///         Env: `STOCK_FACTORY`; `BASE` (the bStock); `START_AMOUNT` in raw bStock units (18 decimals: the market cap
///         at the launch price, e.g. 14.7e18 NVDAB ≈ $3.1K), 0 removes the base.
///
///   STOCK_FACTORY=0x… BASE=0x… START_AMOUNT=14700000000000000000 \
///     forge script script/StockBase.s.sol --rpc-url bsc --account <owner> --broadcast
contract StockBase is Script {
    error NotEighteenDecimals(uint8 decimals);

    function run() external {
        StockLaunchFactory factory = StockLaunchFactory(vm.envAddress("STOCK_FACTORY"));
        address base = vm.envAddress("BASE");
        uint256 startAmount = vm.envUint("START_AMOUNT");
        string memory symbol = IERC20Symbol(base).symbol();
        uint8 decimals = IERC20Symbol(base).decimals();
        if (decimals != 18) revert NotEighteenDecimals(decimals);
        uint256 before = factory.startAmountOf(base);
        vm.startBroadcast();
        factory.setBase(base, startAmount);
        vm.stopBroadcast();
        console2.log("base", symbol, base);
        console2.log("start amount before", before);
        console2.log("start amount now", factory.startAmountOf(base));
        if (startAmount == 0) console2.log("removed for new launches");
    }
}
