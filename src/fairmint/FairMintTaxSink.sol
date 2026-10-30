// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPancakeV2Router} from "./IPancakeV2.sol";

/// @title FairMintTaxSink
/// @notice Receives the platform's 10% share of every fair mint token tax. The keeper sells those tokens on
///         PancakeSwap V2 and the BNB goes straight to SuanBuyBurn (buys back $SUAN). There is no other way out: no
///         withdrawal, no token rescue. Fair mint tokens exempt this contract from their own tax.
contract FairMintTaxSink is Ownable2Step {
    using SafeERC20 for IERC20;

    IPancakeV2Router public immutable v2Router;
    address public immutable wbnb;
    address public immutable suanBuyBurn;
    address public keeper;

    error NotKeeper();
    error ZeroAddress();

    event KeeperSet(address keeper);
    event Converted(address indexed token, uint256 amountIn, uint256 bnbOut);

    constructor(address v2Router_, address suanBuyBurn_, address keeper_, address owner_) Ownable(owner_) {
        if (v2Router_ == address(0) || suanBuyBurn_ == address(0) || keeper_ == address(0)) revert ZeroAddress();
        v2Router = IPancakeV2Router(v2Router_);
        wbnb = IPancakeV2Router(v2Router_).WETH();
        suanBuyBurn = suanBuyBurn_;
        keeper = keeper_;
        emit KeeperSet(keeper_);
    }

    function setKeeper(address keeper_) external onlyOwner {
        if (keeper_ == address(0)) revert ZeroAddress();
        keeper = keeper_;
        emit KeeperSet(keeper_);
    }

    /// @notice Sell `amount` of `token` for at least `minBnb`, paid straight to SuanBuyBurn.
    function convert(address token, uint256 amount, uint256 minBnb, uint256 deadline) external {
        if (msg.sender != keeper) revert NotKeeper();
        IERC20(token).forceApprove(address(v2Router), amount);
        address[] memory path = new address[](2);
        path[0] = token;
        path[1] = wbnb;
        uint256 before = suanBuyBurn.balance;
        v2Router.swapExactTokensForETHSupportingFeeOnTransferTokens(amount, minBnb, path, suanBuyBurn, deadline);
        emit Converted(token, amount, suanBuyBurn.balance - before);
    }
}
