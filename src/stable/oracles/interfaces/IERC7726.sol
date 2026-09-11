// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice ERC-7726 Common Quote Oracle (draft): amounts in native token units, rounded down.
/// @dev The standard supplies no timestamps or validity metadata. The implementation owns freshness.
interface IERC7726 {
    function getQuote(uint256 baseAmount, address base, address quote) external view returns (uint256 quoteAmount);
}
