// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PriceRatioMath} from "./PriceRatioMath.sol";

/// @notice Compatibility entrypoint for eight-decimal Atlas prices; conversion lives in PriceRatioMath.
library AtlasPriceMath {
    uint8 internal constant MAX_TOKEN_DECIMALS = 38;
    // Preserve existing error selectors for consumers of the Atlas-only API.
    error ZeroPrice();
    error UnsupportedDecimals(uint8 decimals);
    error SqrtPriceOutOfBounds();

    function toSqrtPriceX96(uint64 price0, uint64 price1, uint8 decimals0, uint8 decimals1)
        internal
        pure
        returns (uint160)
    {
        if (decimals0 > MAX_TOKEN_DECIMALS) revert UnsupportedDecimals(decimals0);
        if (decimals1 > MAX_TOKEN_DECIMALS) revert UnsupportedDecimals(decimals1);
        (uint256 numerator, uint256 denominator) =
            PriceRatioMath.scale(price0, price1, int256(uint256(decimals1)) - int256(uint256(decimals0)));
        return PriceRatioMath.toSqrtPriceX96(numerator, denominator);
    }
}
