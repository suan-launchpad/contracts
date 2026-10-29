// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {KnownPools} from "./KnownPools.sol";

/// @notice The pools a stock-meme token could be paired in outside its own: everything `KnownPools` lists for WBNB and
///         USDT, plus PancakeSwap and Uniswap V2 / V3 pools against the token's own bStock.
library StockKnownPools {
    uint256 internal constant COUNT = KnownPools.COUNT + 10;

    function all(address token, address base) internal pure returns (address[] memory pools) {
        address[] memory quotePools = KnownPools.all(token);
        pools = new address[](COUNT);
        uint256 n;
        for (; n < quotePools.length; ++n) {
            pools[n] = quotePools[n];
        }
        uint24[4] memory pcsFees = [uint24(100), 500, 2500, 10000];
        uint24[4] memory uniFees = [uint24(100), 500, 3000, 10000];
        pools[n++] = KnownPools.v2Pair(token, base);
        pools[n++] = KnownPools.uniV2Pair(token, base);
        for (uint256 j; j < 4; ++j) {
            pools[n++] = KnownPools.v3Pool(token, base, pcsFees[j]);
            pools[n++] = KnownPools.uniV3Pool(token, base, uniFees[j]);
        }
    }
}
