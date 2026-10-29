// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {Currency} from "infinity-core/src/types/Currency.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "infinity-core/src/types/BalanceDelta.sol";
import {IVault} from "infinity-core/src/interfaces/IVault.sol";
import {ILockCallback} from "infinity-core/src/interfaces/ILockCallback.sol";
import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {TickMath} from "infinity-core/src/pool-cl/libraries/TickMath.sol";
import {IMsgSender} from "./interfaces/IAgentLaunch.sol";
import {IStockLaunchLookup, IV3SwapRouter, IWBNB} from "./interfaces/IStockLaunch.sol";
import {V3Path} from "./libraries/V3Path.sol";

/// @title StockRouter
/// @notice Exact-input router for stock-meme pools. Buys with the bStock, or with BNB in one transaction (wrap →
///         PancakeSwap V3 path to the bStock → meme pool); sells to the bStock, or on to BNB. Exposes `msgSender()` so
///         the hook's .ai checks see the wallet that started the call. Holds nothing between transactions.
contract StockRouter is ILockCallback, IMsgSender {
    using SafeERC20 for IERC20;
    using BalanceDeltaLibrary for BalanceDelta;

    IVault public immutable vault;
    ICLPoolManager public immutable poolManager;
    IV3SwapRouter public immutable v3Router;
    IWBNB public immutable wbnb;

    uint256 private constant LOCKER_SLOT = uint256(keccak256("dotai.stockrouter.locker"));

    error OnlyVault();
    error OnlyWbnb();
    error UnknownPool();
    error TooLittleReceived(uint256 out);
    error Reentered();
    error SendFailed();

    struct SwapData {
        PoolKey key;
        bool memeIs0;
        bool isBuy;
        uint256 amountIn;
        address payer;
        address recipient;
    }

    constructor(IVault vault_, ICLPoolManager poolManager_, address v3Router_, address wbnb_) {
        vault = vault_;
        poolManager = poolManager_;
        v3Router = IV3SwapRouter(v3Router_);
        wbnb = IWBNB(wbnb_);
    }

    /// @dev Only WBNB unwrapping sends BNB here.
    receive() external payable {
        if (msg.sender != address(wbnb)) revert OnlyWbnb();
    }

    function msgSender() external view returns (address locker) {
        uint256 slot = LOCKER_SLOT;
        assembly ("memory-safe") {
            locker := tload(slot)
        }
    }

    /// @notice Buy with `amountIn` of the pool's bStock (approve this router first).
    function buy(PoolKey calldata key, uint256 amountIn, uint256 minOut, address recipient) external returns (uint256 out) {
        _enter();
        (bool memeIs0,) = _sides(key);
        (out,) = _swap(key, memeIs0, true, amountIn, msg.sender, recipient);
        _exit();
        if (out < minOut) revert TooLittleReceived(out);
    }

    /// @notice Buy with BNB (`msg.value`): wrap, swap to the bStock on PancakeSwap V3, then buy in the meme pool.
    /// @param path V3 path from WBNB to the pool's bStock
    /// @param minBaseOut least bStock from the V3 leg (from the quote)
    /// @param minOut least meme tokens the recipient must receive
    function buyWithBnb(PoolKey calldata key, bytes calldata path, uint256 minBaseOut, uint256 minOut, address recipient)
        external
        payable
        returns (uint256 out)
    {
        _enter();
        (bool memeIs0, address base) = _sides(key);
        V3Path.check(path, address(wbnb), base);
        wbnb.deposit{value: msg.value}();
        uint256 baseIn = _v3Swap(address(wbnb), base, path, msg.value, minBaseOut);
        uint256 paid;
        (out, paid) = _swap(key, memeIs0, true, baseIn, address(this), recipient);
        if (baseIn > paid) IERC20(base).safeTransfer(msg.sender, baseIn - paid);
        _exit();
        if (out < minOut) revert TooLittleReceived(out);
    }

    /// @notice Sell `amountIn` meme tokens for the bStock (approve this router first).
    function sell(PoolKey calldata key, uint256 amountIn, uint256 minOut, address recipient) external returns (uint256 out) {
        _enter();
        (bool memeIs0,) = _sides(key);
        (out,) = _swap(key, memeIs0, false, amountIn, msg.sender, recipient);
        _exit();
        if (out < minOut) revert TooLittleReceived(out);
    }

    /// @notice Sell `amountIn` meme tokens and swap the bStock on to BNB on PancakeSwap V3.
    /// @param path V3 path from the pool's bStock to WBNB
    /// @param minBnbOut least BNB the recipient must receive
    function sellForBnb(PoolKey calldata key, uint256 amountIn, bytes calldata path, uint256 minBnbOut, address recipient)
        external
        returns (uint256 bnbOut)
    {
        _enter();
        (bool memeIs0, address base) = _sides(key);
        V3Path.check(path, base, address(wbnb));
        (uint256 baseOut,) = _swap(key, memeIs0, false, amountIn, msg.sender, address(this));
        bnbOut = _v3Swap(base, address(wbnb), path, baseOut, minBnbOut);
        wbnb.withdraw(bnbOut);
        (bool ok,) = recipient.call{value: bnbOut}("");
        if (!ok) revert SendFailed();
        _exit();
    }

    /// @notice Swap BNB to a bStock on PancakeSwap V3, e.g. to fund a creator presale.
    /// @param path V3 path from WBNB to the bStock
    function bnbToBase(bytes calldata path, address base, uint256 minOut, address recipient)
        external
        payable
        returns (uint256 out)
    {
        V3Path.check(path, address(wbnb), base);
        wbnb.deposit{value: msg.value}();
        out = _v3Swap(address(wbnb), base, path, msg.value, minOut);
        IERC20(base).safeTransfer(recipient, out);
    }

    function lockAcquired(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(vault)) revert OnlyVault();
        SwapData memory s = abi.decode(data, (SwapData));
        (Currency memeC, Currency baseC) = s.memeIs0 ? (s.key.currency0, s.key.currency1) : (s.key.currency1, s.key.currency0);
        bool zeroForOne = s.isBuy != s.memeIs0;
        ICLPoolManager.SwapParams memory params = ICLPoolManager.SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: -int256(s.amountIn),
            sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_RATIO + 1 : TickMath.MAX_SQRT_RATIO - 1
        });

        if (s.isBuy) {
            // During a launch's hold-cap window the hook delivers the tokens itself, to the recipient passed as hook
            // data; afterwards they are taken here. Either way `out` is what the recipient received.
            IERC20 meme = IERC20(Currency.unwrap(memeC));
            uint256 before = meme.balanceOf(s.recipient);
            BalanceDelta d = poolManager.swap(s.key, params, abi.encode(s.recipient));
            (int128 memeDelta, int128 baseDelta) = s.memeIs0 ? (d.amount0(), d.amount1()) : (d.amount1(), d.amount0());
            uint256 paid = uint256(uint128(-baseDelta));
            _pay(baseC, s.payer, paid);
            if (memeDelta > 0) vault.take(memeC, s.recipient, uint256(uint128(memeDelta)));
            return abi.encode(meme.balanceOf(s.recipient) - before, paid);
        }
        BalanceDelta sd = poolManager.swap(s.key, params, "");
        (int128 memeD, int128 baseD) = s.memeIs0 ? (sd.amount0(), sd.amount1()) : (sd.amount1(), sd.amount0());
        uint256 memeIn = uint256(uint128(-memeD));
        _pay(memeC, s.payer, memeIn);
        uint256 out = uint256(uint128(baseD));
        vault.take(baseC, s.recipient, out);
        return abi.encode(out, memeIn);
    }

    function _swap(PoolKey calldata key, bool memeIs0, bool isBuy, uint256 amountIn, address payer, address recipient)
        private
        returns (uint256 out, uint256 paid)
    {
        bytes memory res = vault.lock(
            abi.encode(
                SwapData({key: key, memeIs0: memeIs0, isBuy: isBuy, amountIn: amountIn, payer: payer, recipient: recipient})
            )
        );
        (out, paid) = abi.decode(res, (uint256, uint256));
    }

    function _pay(Currency c, address payer, uint256 amount) private {
        vault.sync(c);
        IERC20 token = IERC20(Currency.unwrap(c));
        if (payer == address(this)) token.safeTransfer(address(vault), amount);
        else token.safeTransferFrom(payer, address(vault), amount);
        vault.settle();
    }

    function _v3Swap(address tokenIn, address tokenOut, bytes calldata path, uint256 amountIn, uint256 minOut)
        private
        returns (uint256 out)
    {
        uint256 before = IERC20(tokenOut).balanceOf(address(this));
        IERC20(tokenIn).forceApprove(address(v3Router), amountIn);
        v3Router.exactInput(
            IV3SwapRouter.ExactInputParams({
                path: path, recipient: address(this), deadline: block.timestamp, amountIn: amountIn, amountOutMinimum: minOut
            })
        );
        out = IERC20(tokenOut).balanceOf(address(this)) - before;
        if (out < minOut) revert TooLittleReceived(out);
    }

    /// @return memeIs0 whether the meme is currency0; base the pool's bStock
    function _sides(PoolKey calldata key) private view returns (bool memeIs0, address base) {
        IStockLaunchLookup hook = IStockLaunchLookup(address(key.hooks));
        address c0 = Currency.unwrap(key.currency0);
        address c1 = Currency.unwrap(key.currency1);
        if (hook.baseOf(c1) == c0 && c0 != address(0)) return (false, c0);
        if (hook.baseOf(c0) == c1 && c1 != address(0)) return (true, c1);
        revert UnknownPool();
    }

    function _enter() private {
        uint256 slot = LOCKER_SLOT;
        address current;
        assembly ("memory-safe") {
            current := tload(slot)
        }
        if (current != address(0)) revert Reentered();
        address sender = msg.sender;
        assembly ("memory-safe") {
            tstore(slot, sender)
        }
    }

    function _exit() private {
        uint256 slot = LOCKER_SLOT;
        assembly ("memory-safe") {
            tstore(slot, 0)
        }
    }
}
