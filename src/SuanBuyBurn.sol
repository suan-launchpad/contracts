// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @notice The Flap Portal surface the buyback needs: a native-BNB buy, routed to the bonding curve before graduation
///         and to the DEX pool after it.
interface IFlapPortal {
    struct ExactInputParams {
        address inputToken;
        address outputToken;
        uint256 inputAmount;
        uint256 minOutputAmount;
        bytes permitData;
    }

    function swapExactInput(ExactInputParams calldata params) external payable returns (uint256 outputAmount);
}

/// @title SuanBuyBurn
/// @notice Receives the launchpad's platform fees in BNB (the platform half of every trade's base fee and every launch
///         fee) and spends all of it buying $SUAN through the Flap Portal, sending what it buys to the dead address.
///         There is no other way out for the BNB: no withdrawal, no owner transfer. Only the keeper triggers a buy and
///         it names the least $SUAN that must be burned, so a buy cannot be pulled into a sandwich.
contract SuanBuyBurn is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;

    IFlapPortal public immutable portal;
    IERC20 public immutable suan;
    address public keeper;

    uint256 public totalBnbSpent;
    uint256 public totalSuanBurned;

    event Received(address indexed from, uint256 amount);
    event SuanBurned(uint256 bnbIn, uint256 suanBurned);
    event KeeperSet(address keeper);

    error ZeroAddress();
    error NotKeeper();
    error NothingToSpend();
    error InsufficientBurn(uint256 burned, uint256 minBurned);

    constructor(address portal_, address suan_, address keeper_, address owner_) Ownable(owner_) {
        if (portal_ == address(0) || suan_ == address(0) || keeper_ == address(0)) revert ZeroAddress();
        portal = IFlapPortal(portal_);
        suan = IERC20(suan_);
        keeper = keeper_;
        emit KeeperSet(keeper_);
    }

    receive() external payable {
        emit Received(msg.sender, msg.value);
    }

    function setKeeper(address keeper_) external onlyOwner {
        if (keeper_ == address(0)) revert ZeroAddress();
        keeper = keeper_;
        emit KeeperSet(keeper_);
    }

    /// @param maxBnb spend at most this much of the balance
    /// @param minSuanBurned the least $SUAN the dead address must receive, from the keeper's quote
    function buyAndBurn(uint256 maxBnb, uint256 minSuanBurned) external nonReentrant returns (uint256 burned) {
        if (msg.sender != keeper) revert NotKeeper();
        uint256 balance = address(this).balance;
        uint256 amount = balance < maxBnb ? balance : maxBnb;
        if (amount == 0) revert NothingToSpend();

        uint256 before = suan.balanceOf(address(this));
        portal.swapExactInput{value: amount}(
            IFlapPortal.ExactInputParams({
                inputToken: address(0),
                outputToken: address(suan),
                inputAmount: amount,
                minOutputAmount: 0,
                permitData: ""
            })
        );
        uint256 bought = suan.balanceOf(address(this)) - before;

        uint256 deadBefore = suan.balanceOf(DEAD);
        suan.safeTransfer(DEAD, bought);
        burned = suan.balanceOf(DEAD) - deadBefore;
        if (burned < minSuanBurned) revert InsufficientBurn(burned, minSuanBurned);

        totalBnbSpent += amount;
        totalSuanBurned += burned;
        emit SuanBurned(amount, burned);
    }
}
