// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

/// @notice Exact rational scaling and sqrtPriceX96 conversion, independent of oracle provider.
library PriceRatioMath {
    uint8 internal constant MAX_TOKEN_DECIMALS = 38;
    error ZeroPrice();
    error UnsupportedDecimals(uint8 decimals);
    error UnsupportedScale();
    error RatioOverflow();
    error SqrtPriceOutOfBounds();

    /// @notice Apply a decimal exponent to a positive ratio without rounding.
    /// @dev Cancels common factors before multiplication; rejects unrepresentable uint256 components.
    function scale(uint256 numerator, uint256 denominator, int256 exponent) internal pure returns (uint256, uint256) {
        if (numerator == 0 || denominator == 0) revert ZeroPrice();
        if (exponent < -77 || exponent > 77) revert UnsupportedScale();
        uint256 common = FixedPointMathLib.gcd(numerator, denominator);
        numerator /= common;
        denominator /= common;
        if (exponent >= 0) {
            uint256 factor = 10 ** uint256(exponent);
            common = FixedPointMathLib.gcd(denominator, factor);
            denominator /= common;
            factor /= common;
            if (numerator > type(uint256).max / factor) revert RatioOverflow();
            numerator *= factor;
        } else {
            uint256 factor = 10 ** uint256(-exponent);
            common = FixedPointMathLib.gcd(numerator, factor);
            numerator /= common;
            factor /= common;
            if (denominator > type(uint256).max / factor) revert RatioOverflow();
            denominator *= factor;
        }
        return (numerator, denominator);
    }

    /// @return sqrtPriceX96 floor(sqrt(numerator / denominator) * 2**96), in v4's valid range.
    /// @dev Components are raw token amounts, NOT whole-token prices. Supports full uint256 inputs.
    function toSqrtPriceX96(uint256 numerator, uint256 denominator) internal pure returns (uint160 sqrtPriceX96) {
        if (numerator == 0 || denominator == 0) revert ZeroPrice();
        uint256 integerRatio = numerator / denominator;
        if (integerRatio >= (uint256(1) << 128)) revert SqrtPriceOutOfBounds();
        uint256 root;
        if (integerRatio < (uint256(1) << 64)) {
            root = FixedPointMathLib.sqrt(FullMath.mulDiv(numerator, uint256(1) << 192, denominator));
        } else {
            // Exact 320-bit Q192 value represented as high * 2**64 + low.
            uint256 high = FullMath.mulDiv(numerator, uint256(1) << 128, denominator);
            uint256 low =
                FullMath.mulDiv(mulmod(numerator, uint256(1) << 128, denominator), uint256(1) << 64, denominator);
            // Strict upper root estimate within 2**32 of a root >= 2**128.
            root = (FixedPointMathLib.sqrt(high) + 1) << 32;
            // Two integer Newton steps recover the exact floor, including perfect-square cycles.
            uint256 next = (root + _divideQ192(high, low, root)) >> 1;
            root = (next + _divideQ192(high, low, next)) >> 1;
            if (next < root) root = next;
        }
        if (root < TickMath.MIN_SQRT_PRICE || root >= TickMath.MAX_SQRT_PRICE) revert SqrtPriceOutOfBounds();
        sqrtPriceX96 = uint160(root);
    }

    /// @dev Divide a 320-bit value by the root estimate without multiplying the oracle denominator by it.
    function _divideQ192(uint256 high, uint256 low, uint256 divisor) private pure returns (uint256) {
        return
            FullMath.mulDiv(high, uint256(1) << 64, divisor) + (mulmod(high, uint256(1) << 64, divisor) + low) / divisor;
    }
}
