// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice ABI-compatible subset of Steer Atlas's V3 resolver interface.
/// @dev Atlas's upstream interface pins Solidity 0.8.35; this consumer uses the same ABI on 0.8.26.
interface IMarketPriceResolverV3 {
    struct PriceBatch {
        uint64 canonicalEpoch;
        uint64 observedAt;
        uint64 validUntil;
        uint64[] values;
    }

    /// @notice Read positive, eight-decimal prices from one canonical market-state snapshot.
    /// @dev Reverts for unavailable feeds, including unsupported proof-only routes.
    function getPrices(bytes32[] calldata feedIds) external view returns (PriceBatch memory result);
}
