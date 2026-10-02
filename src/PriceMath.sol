// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";

/// @title PriceMath
/// @notice Turns a pair of amounts into the Uniswap v4 sqrtPriceX96 at which they are worth the same.
/// Shared by `ForeverLiquidity` and the deploy script so both compute the opening price identically.
library PriceMath {
    error ZeroAmount();
    error PriceOutOfRange();

    /// @notice The sqrtPriceX96 at which `tokenAmount` of currency1 is worth `ethAmount` of currency0.
    /// Reverts `PriceOutOfRange` when the ratio cannot be represented (token-per-wei ratio of 2^64 and
    /// above) or lies outside the pool's tick range.
    function sqrtPriceX96ForAmounts(uint256 ethAmount, uint256 tokenAmount) internal pure returns (uint160) {
        if (ethAmount < 1 || tokenAmount < 1) revert ZeroAmount();
        // tokenAmount * 2^192 / ethAmount overflows 256 bits once the ratio reaches 2^64.
        if (tokenAmount / ethAmount >= (uint256(1) << 64)) revert PriceOutOfRange();
        uint256 ratioX192 = Math.mulDiv(tokenAmount, 1 << 192, ethAmount);
        uint256 sqrtPriceX96 = Math.sqrt(ratioX192);
        if (sqrtPriceX96 < TickMath.MIN_SQRT_PRICE || sqrtPriceX96 >= TickMath.MAX_SQRT_PRICE) {
            revert PriceOutOfRange();
        }
        return uint160(sqrtPriceX96);
    }
}
