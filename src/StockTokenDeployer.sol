// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {StockToken} from "./StockToken.sol";

/// @title StockTokenDeployer
/// @notice Deploys StockTokens for the StockLaunchFactory that created it, keeping the token's creation code out of the
///         factory's runtime code (contract size limit).
contract StockTokenDeployer {
    address public immutable factory;

    error OnlyFactory();

    constructor() {
        factory = msg.sender;
    }

    function deploy(StockToken.Config calldata c) external returns (StockToken) {
        if (msg.sender != factory) revert OnlyFactory();
        return new StockToken(c);
    }
}
