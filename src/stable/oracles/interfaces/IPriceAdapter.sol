// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice A validated reference ratio for one immutable, address-ordered ERC-20 pair.
interface IPriceAdapter {
    struct Price {
        // Raw token1 units per raw token0 unit. Token and feed decimals are already accounted for.
        uint256 numerator;
        uint256 denominator;
        // Both zero means metadata is unavailable, NOT that the source was observed just now.
        uint64 observedAt;
        uint64 validUntil;
        // Opaque source-local identifier. Zero if unavailable; do not compare across adapters.
        bytes32 updateId;
    }

    function token0() external view returns (address);
    function token1() external view returns (address);
    /// @dev Implementations enforce their source-specific validity policy and propagate read failures.
    function readPrice() external view returns (Price memory);
}
