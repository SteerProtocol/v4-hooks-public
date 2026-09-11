// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BasePriceAdapter} from "./BasePriceAdapter.sol";
import {IERC7726} from "../interfaces/IERC7726.sol";

/// @notice Consume an ERC-7726 draft quote oracle as a raw token1/token0 reference ratio.
/// @dev The selected oracle MUST enforce acceptable freshness and return reference-value quotes.
///      ERC-7726 provides no timestamps. This adapter cannot independently check their age.
contract ERC7726PriceAdapter is BasePriceAdapter {
    IERC7726 public immutable oracle;
    uint256 public immutable baseAmount;
    error InvalidOracle();
    error InvalidBaseAmount();
    error ZeroQuote();

    /// @param baseAmount_ Sampling amount in raw token0 units; tune to avoid material quote rounding.
    constructor(IERC7726 oracle_, address token0_, address token1_, uint256 baseAmount_)
        BasePriceAdapter(token0_, token1_)
    {
        if (address(oracle_).code.length == 0) revert InvalidOracle();
        if (baseAmount_ == 0) revert InvalidBaseAmount();
        oracle = oracle_;
        baseAmount = baseAmount_;
    }

    function readPrice() external view override returns (Price memory result) {
        uint256 quote = oracle.getQuote(baseAmount, token0, token1);
        if (quote == 0) revert ZeroQuote();
        // Amounts already include token decimals. Applying decimal normalization again would be incorrect.
        result.numerator = quote;
        result.denominator = baseAmount;
        // Timestamps and updateId stay zero because the source interface does not supply them.
    }
}
