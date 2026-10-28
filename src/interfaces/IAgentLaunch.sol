// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// `taxSeconds` value for a tax period that never ends: .ai wallets keep their lower rate and the token only ever
// trades in its own pool.
uint64 constant PERMANENT = type(uint64).max;

/// @notice SPACE ID "Agent ID" (.ai) NFT on BSC. Non-transferable; holding one means the wallet has a Binance Agent ID.
interface IAgentId {
    function balanceOf(address owner) external view returns (uint256);
}

/// @notice Routers that expose the address that started the call (Uniswap v4 / PancakeSwap Infinity periphery pattern).
interface IMsgSender {
    function msgSender() external view returns (address);
}

/// @notice What the token needs from the hook while a transfer is running.
interface IAgentHookContext {
    /// @notice Spend `amount` of the calling token's Vault budget for this transaction. Swaps in the token's own pool
    ///         credit it: tokens bought there may leave the Vault as ERC20, tokens sold there may enter it.
    /// @param inbound true for a transfer into the Vault, false for one out of it
    /// @return false when the remaining budget does not cover `amount`
    function useVaultFlow(bool inbound, uint256 amount) external returns (bool);

    /// @return the creator receiving the launch presale, or address(0) outside of it
    function presaleRecipient(address token) external view returns (address);
}

interface IAgentToken {
    function isRewardExcluded(address account) external view returns (bool);
}

interface IHolderRewards {
    function setShare(address account, uint256 balance) external;
    function deposit() external payable;
}
