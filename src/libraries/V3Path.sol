// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice Checks on a PancakeSwap V3 multi-hop path: `token (20) | fee (3) | token (20) | ...`.
library V3Path {
    uint256 private constant ADDR = 20;
    uint256 private constant HOP = 23;

    error InvalidPath();

    /// @dev Reverts unless `path` has at least one hop, starts at `tokenIn` and ends at `tokenOut`.
    function check(bytes calldata path, address tokenIn, address tokenOut) internal pure {
        if (path.length < ADDR + HOP || (path.length - ADDR) % HOP != 0) revert InvalidPath();
        if (address(bytes20(path[:ADDR])) != tokenIn) revert InvalidPath();
        if (address(bytes20(path[path.length - ADDR:])) != tokenOut) revert InvalidPath();
    }
}
