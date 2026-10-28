// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "infinity-core/src/types/Currency.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "infinity-core/src/types/BalanceDelta.sol";
import {IVault} from "infinity-core/src/interfaces/IVault.sol";
import {ILockCallback} from "infinity-core/src/interfaces/ILockCallback.sol";
import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {TickMath} from "infinity-core/src/pool-cl/libraries/TickMath.sol";
import {IMsgSender} from "./interfaces/IAgentLaunch.sol";

/// @title AgentRouter
/// @notice Minimal exact-input router for BNB <-> launch token swaps in a hooked Infinity pool. Exposes
///         `msgSender()` so the hook can check who started the call. Usable from Agentic Wallet Developer Mode
///         (`baw contract-call`) and in tests.
contract AgentRouter is ILockCallback, IMsgSender {
    using CurrencyLibrary for Currency;
    using BalanceDeltaLibrary for BalanceDelta;

    IVault public immutable vault;
    ICLPoolManager public immutable poolManager;

    uint256 private constant LOCKER_SLOT = uint256(keccak256("dotai.router.locker"));

    error OnlyVault();
    error TooLittleReceived(uint256 out);
    error Reentered();

    constructor(IVault vault_, ICLPoolManager poolManager_) {
        vault = vault_;
        poolManager = poolManager_;
    }

    receive() external payable {}

    function msgSender() external view returns (address locker) {
        uint256 slot = LOCKER_SLOT;
        assembly ("memory-safe") {
            locker := tload(slot)
        }
    }

    /// @notice Buy with BNB (`msg.value`). `sqrtPriceLimitX96` = 0 means no limit.
    function buy(PoolKey calldata key, uint160 sqrtPriceLimitX96, uint256 minOut, address recipient)
        external
        payable
        returns (uint256 out)
    {
        uint160 limit = sqrtPriceLimitX96 == 0 ? TickMath.MIN_SQRT_RATIO + 1 : sqrtPriceLimitX96;
        out = _swap(key, true, msg.value, limit, minOut, recipient);
        uint256 left = address(this).balance;
        if (left > 0) {
            (bool ok,) = msg.sender.call{value: left}("");
            require(ok, "refund");
        }
    }

    /// @notice Sell `amountIn` tokens (approve this router first).
    function sell(PoolKey calldata key, uint256 amountIn, uint256 minOut, address recipient) external returns (uint256 out) {
        out = _swap(key, false, amountIn, TickMath.MAX_SQRT_RATIO - 1, minOut, recipient);
    }

    function _swap(PoolKey calldata key, bool zeroForOne, uint256 amountIn, uint160 limit, uint256 minOut, address recipient)
        private
        returns (uint256 out)
    {
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
        bytes memory res = vault.lock(abi.encode(key, zeroForOne, amountIn, limit, sender, recipient));
        assembly ("memory-safe") {
            tstore(slot, 0)
        }
        out = abi.decode(res, (uint256));
        if (out < minOut) revert TooLittleReceived(out);
    }

    function lockAcquired(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(vault)) revert OnlyVault();
        (PoolKey memory key, bool zeroForOne, uint256 amountIn, uint160 limit, address payer, address recipient) =
            abi.decode(data, (PoolKey, bool, uint256, uint160, address, address));

        ICLPoolManager.SwapParams memory params =
            ICLPoolManager.SwapParams({zeroForOne: zeroForOne, amountSpecified: -int256(amountIn), sqrtPriceLimitX96: limit});
        uint256 out;
        if (zeroForOne) {
            // pay BNB, receive token. During a launch's hold-cap window the hook delivers the tokens itself, to the
            // recipient passed as hook data; afterwards they are taken here. Either way `out` is what the recipient
            // received.
            IERC20 token = IERC20(Currency.unwrap(key.currency1));
            uint256 before = token.balanceOf(recipient);
            BalanceDelta d = poolManager.swap(key, params, abi.encode(recipient));
            vault.settle{value: uint256(uint128(-d.amount0()))}();
            if (d.amount1() > 0) vault.take(key.currency1, recipient, uint256(uint128(d.amount1())));
            out = token.balanceOf(recipient) - before;
        } else {
            BalanceDelta d = poolManager.swap(key, params, "");
            int128 a0 = d.amount0();
            int128 a1 = d.amount1();
            // pay token, receive BNB
            vault.sync(key.currency1);
            IERC20(Currency.unwrap(key.currency1)).transferFrom(payer, address(vault), uint256(uint128(-a1)));
            vault.settle();
            out = uint256(uint128(a0));
            vault.take(CurrencyLibrary.NATIVE, recipient, out);
        }
        return abi.encode(out);
    }
}
