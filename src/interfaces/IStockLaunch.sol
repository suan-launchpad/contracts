// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice What a stock-meme token and its hook need from the token's holder-rewards contract.
interface IStockHolderRewards {
    function setShare(address account, uint256 balance) external;
    /// @notice The hook minted `amount` of the base as Vault claims to the rewards contract; distribute it.
    function notifyReward(uint256 amount) external;
}

/// @notice Lookup the StockRouter uses to tell the meme from the base in a pool key.
interface IStockLaunchLookup {
    /// @return the bStock a launch token trades against, or address(0) for an unknown token
    function baseOf(address token) external view returns (address);
}

/// @notice PancakeSwap V3 SwapRouter (`0x1b81…eB14` on BSC), exact-input multi-hop.
interface IV3SwapRouter {
    struct ExactInputParams {
        bytes path;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
    }

    function exactInput(ExactInputParams calldata params) external payable returns (uint256 amountOut);
}

interface IWBNB {
    function deposit() external payable;
    function withdraw(uint256 amount) external;
}
