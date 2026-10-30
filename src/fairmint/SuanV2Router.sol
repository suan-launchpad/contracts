// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IPancakeV2Factory, IPancakeV2Pair, IPancakeV2Router, IWBNB} from "./IPancakeV2.sol";

/// @title SuanV2Router
/// @notice The SUAN website's and skill's way to trade BNB pairs on PancakeSwap V2. Each trade pays a 1% fee in BNB
///         to SuanBuyBurn (buys back $SUAN): on a buy it comes out of the BNB sent, on a sell out of the BNB received.
///         Anyone can skip this router and trade on PancakeSwap directly.
/// @dev Holds nothing between calls, has no owner and no upgrade path. A sell moves the caller's tokens straight into
///      the pair (so a token's tax sees the real seller, e.g. for a `.ai` discount) and swaps against the pair.
contract SuanV2Router is ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint16 public constant FEE_BPS = 100;
    uint16 internal constant BPS = 10_000;

    IPancakeV2Router public immutable v2Router;
    IPancakeV2Factory public immutable v2Factory;
    address public immutable wbnb;
    address public immutable suanBuyBurn;

    error ZeroAddress();
    error ZeroAmount();
    error InsufficientOutput(uint256 out);
    error TransferFailed();
    error NotRouter();
    error NoPair();
    error Expired();

    event Bought(address indexed user, address indexed token, uint256 bnbIn, uint256 tokensOut, uint256 fee);
    event Sold(address indexed user, address indexed token, uint256 tokensIn, uint256 bnbOut, uint256 fee);

    constructor(address v2Router_, address suanBuyBurn_) {
        if (v2Router_ == address(0) || suanBuyBurn_ == address(0)) revert ZeroAddress();
        v2Router = IPancakeV2Router(v2Router_);
        wbnb = IPancakeV2Router(v2Router_).WETH();
        v2Factory = IPancakeV2Factory(IPancakeV2Router(v2Router_).factory());
        suanBuyBurn = suanBuyBurn_;
    }

    /// @notice BNB arrives here only from WBNB while selling.
    receive() external payable {
        if (msg.sender != wbnb) revert NotRouter();
    }

    /// @notice Buy `token` with `msg.value` BNB; tokens go to `to`.
    function buy(address token, uint256 minTokensOut, address to, uint256 deadline)
        external
        payable
        nonReentrant
        returns (uint256 tokensOut)
    {
        if (msg.value == 0) revert ZeroAmount();
        uint256 fee = msg.value * FEE_BPS / BPS;
        uint256 before = IERC20(token).balanceOf(to);
        v2Router.swapExactETHForTokensSupportingFeeOnTransferTokens{value: msg.value - fee}(
            minTokensOut, _path(wbnb, token), to, deadline
        );
        tokensOut = IERC20(token).balanceOf(to) - before;
        _send(suanBuyBurn, fee);
        emit Bought(msg.sender, token, msg.value, tokensOut, fee);
    }

    /// @notice Sell `amountIn` of `token` (approve this router first); BNB after the fee goes to `to`.
    function sell(address token, uint256 amountIn, uint256 minBnbOut, address to, uint256 deadline)
        external
        nonReentrant
        returns (uint256 bnbOut)
    {
        if (amountIn == 0) revert ZeroAmount();
        if (block.timestamp > deadline) revert Expired();
        address pair = v2Factory.getPair(token, wbnb);
        if (pair == address(0)) revert NoPair();
        bool tokenIs0 = IPancakeV2Pair(pair).token0() == token;
        (uint112 r0, uint112 r1,) = IPancakeV2Pair(pair).getReserves();
        (uint256 reserveIn, uint256 reserveOut) = tokenIs0 ? (uint256(r0), uint256(r1)) : (uint256(r1), uint256(r0));
        IERC20(token).safeTransferFrom(msg.sender, pair, amountIn);
        uint256 received = IERC20(token).balanceOf(pair) - reserveIn; // after any token tax
        uint256 withFee = received * 9975;
        uint256 gross = withFee * reserveOut / (reserveIn * 10_000 + withFee);
        (uint256 out0, uint256 out1) = tokenIs0 ? (uint256(0), gross) : (gross, uint256(0));
        IPancakeV2Pair(pair).swap(out0, out1, address(this), "");
        IWBNB(wbnb).withdraw(gross);
        uint256 fee = gross * FEE_BPS / BPS;
        bnbOut = gross - fee;
        if (bnbOut < minBnbOut) revert InsufficientOutput(bnbOut);
        _send(suanBuyBurn, fee);
        _send(to, bnbOut);
        emit Sold(msg.sender, token, amountIn, bnbOut, fee);
    }

    function _path(address a, address b) private pure returns (address[] memory p) {
        p = new address[](2);
        p[0] = a;
        p[1] = b;
    }

    function _send(address to, uint256 amount) private {
        if (amount == 0) return;
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert TransferFailed();
    }
}
