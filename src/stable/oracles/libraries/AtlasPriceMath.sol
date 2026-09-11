// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

/// @notice Converts common-denomination Atlas prices into a raw token1/token0 sqrt price.
library AtlasPriceMath {
    /// @dev uint64 price * 10**38 fits in uint192. Larger decimal counts are explicitly unsupported.
    uint8 internal constant MAX_TOKEN_DECIMALS = 38;

    error ZeroPrice();
    error UnsupportedDecimals(uint8 decimals);
    error SqrtPriceOutOfBounds();

    /// @return sqrtPriceX96 floor(sqrt(price0 / price1 * 10**(decimals1 - decimals0)) * 2**96).
    /// @dev Both prices must use the same quote denomination and scale, and price one whole token.
    ///      Returns the exact integer floor, including ratios too large for a uint256 Q192 intermediate.
    ///      Enforces v4's [MIN_SQRT_PRICE, MAX_SQRT_PRICE) interval, not StablePair's narrower band bounds.
    function toSqrtPriceX96(uint64 price0, uint64 price1, uint8 decimals0, uint8 decimals1)
        internal
        pure
        returns (uint160 sqrtPriceX96)
    {
        if (price0 == 0 || price1 == 0) revert ZeroPrice();
        if (decimals0 > MAX_TOKEN_DECIMALS) revert UnsupportedDecimals(decimals0);
        if (decimals1 > MAX_TOKEN_DECIMALS) revert UnsupportedDecimals(decimals1);

        uint256 numerator = price0;
        uint256 denominator = price1;
        if (decimals1 >= decimals0) numerator *= 10 ** uint256(decimals1 - decimals0);
        else denominator *= 10 ** uint256(decimals0 - decimals1);

        uint256 integerRatio = numerator / denominator;
        if (integerRatio >= (uint256(1) << 128)) revert SqrtPriceOutOfBounds();

        uint256 root;
        if (integerRatio < (uint256(1) << 64)) {
            // Taking sqrt after flooring the rational Q192 value preserves the exact integer root.
            root = FixedPointMathLib.sqrt(FullMath.mulDiv(numerator, uint256(1) << 192, denominator));
        } else {
            // Here decimals1 > decimals0, so denominator is still an unscaled uint64.
            // Q128 fits in uint256. This gives a strict upper root estimate within 2**32.
            root = (FixedPointMathLib.sqrt(FullMath.mulDiv(numerator, uint256(1) << 128, denominator)) + 1) << 32;
            // The root is >= 2**128, so two integer Newton steps recover the exact floor.
            // denominator * root fits in uint224. min handles the floor/ceil cycle at a square boundary.
            uint256 next = (root + FullMath.mulDiv(numerator, uint256(1) << 192, denominator * root)) >> 1;
            root = (next + FullMath.mulDiv(numerator, uint256(1) << 192, denominator * next)) >> 1;
            if (next < root) root = next;
        }

        if (root < TickMath.MIN_SQRT_PRICE || root >= TickMath.MAX_SQRT_PRICE) revert SqrtPriceOutOfBounds();
        sqrtPriceX96 = uint160(root);
    }
}
