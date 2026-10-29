// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IV3SwapRouter, IWBNB} from "./interfaces/IStockLaunch.sol";
import {V3Path} from "./libraries/V3Path.sol";

/// @title StockFeeSink
/// @notice Receives the platform's half of the stock-meme base fee in bStock and turns it into BNB for SuanBuyBurn,
///         which buys and burns $SUAN with it. Only the keeper converts: bStock → WBNB on PancakeSwap V3 along the
///         keeper's path (direct WBNB pool or via USDT), with the keeper's least WBNB out so a conversion cannot be
///         sandwiched, then unwraps and sends all of it to SuanBuyBurn. There is no withdrawal: the owner can only set
///         the keeper and the V3 router.
contract StockFeeSink is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    IWBNB public immutable wbnb;
    /// @notice The existing SuanBuyBurn (`0xF611…E134A` on BSC).
    address public immutable suanBuyBurn;
    address public keeper;
    /// @notice PancakeSwap V3 SwapRouter used for conversions. Fixed: a settable router would be a withdrawal path.
    address public immutable swapRouter;

    uint256 public totalBnbSent;

    event Converted(address indexed base, uint256 amountIn, uint256 bnbOut);
    event KeeperSet(address keeper);

    error ZeroAddress();
    error NotKeeper();
    error NothingToConvert();
    error InsufficientOutput(uint256 out, uint256 minOut);
    error OnlyWbnb();
    error SendFailed();

    constructor(address wbnb_, address suanBuyBurn_, address swapRouter_, address keeper_, address owner_) Ownable(owner_) {
        if (wbnb_ == address(0) || suanBuyBurn_ == address(0) || swapRouter_ == address(0) || keeper_ == address(0)) {
            revert ZeroAddress();
        }
        wbnb = IWBNB(wbnb_);
        suanBuyBurn = suanBuyBurn_;
        swapRouter = swapRouter_;
        keeper = keeper_;
        emit KeeperSet(keeper_);
    }

    /// @dev Only WBNB unwrapping sends BNB here.
    receive() external payable {
        if (msg.sender != address(wbnb)) revert OnlyWbnb();
    }

    function setKeeper(address keeper_) external onlyOwner {
        if (keeper_ == address(0)) revert ZeroAddress();
        keeper = keeper_;
        emit KeeperSet(keeper_);
    }

    /// @notice Convert up to `amountIn` of `base` held here to BNB and send it to SuanBuyBurn.
    /// @param path V3 path from `base` to WBNB (`base | fee | [USDT | fee |] WBNB`)
    /// @param minWbnbOut the least WBNB the swap must return, from the keeper's quote
    function convert(address base, uint256 amountIn, bytes calldata path, uint256 minWbnbOut)
        external
        nonReentrant
        returns (uint256 bnbOut)
    {
        if (msg.sender != keeper) revert NotKeeper();
        V3Path.check(path, base, address(wbnb));
        uint256 balance = IERC20(base).balanceOf(address(this));
        uint256 amount = balance < amountIn ? balance : amountIn;
        if (amount == 0) revert NothingToConvert();

        address router = swapRouter;
        IERC20 wbnbToken = IERC20(address(wbnb));
        uint256 before = wbnbToken.balanceOf(address(this));
        IERC20(base).forceApprove(router, amount);
        IV3SwapRouter(router).exactInput(
            IV3SwapRouter.ExactInputParams({
                path: path, recipient: address(this), deadline: block.timestamp, amountIn: amount, amountOutMinimum: minWbnbOut
            })
        );
        IERC20(base).forceApprove(router, 0);
        bnbOut = wbnbToken.balanceOf(address(this)) - before;
        if (bnbOut < minWbnbOut) revert InsufficientOutput(bnbOut, minWbnbOut);

        wbnb.withdraw(bnbOut);
        (bool ok,) = suanBuyBurn.call{value: bnbOut}("");
        if (!ok) revert SendFailed();
        totalBnbSent += bnbOut;
        emit Converted(base, amount, bnbOut);
    }
}
