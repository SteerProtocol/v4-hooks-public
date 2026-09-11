// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BasePriceAdapter} from "./BasePriceAdapter.sol";
import {IMarketPriceResolverV3} from "../interfaces/IMarketPriceResolverV3.sol";
import {PriceRatioMath} from "../libraries/PriceRatioMath.sol";

/// @notice Two Atlas feeds in a common denomination, read atomically from one canonical snapshot.
contract AtlasPriceAdapter is BasePriceAdapter {
    IMarketPriceResolverV3 public immutable resolver;
    bytes32 public immutable feedId0;
    bytes32 public immutable feedId1;
    error InvalidResolver();
    error InvalidFeedId();
    error InvalidSnapshot();

    constructor(IMarketPriceResolverV3 resolver_, address token0_, address token1_, bytes32 feedId0_, bytes32 feedId1_)
        BasePriceAdapter(token0_, token1_)
    {
        if (address(resolver_).code.length == 0) revert InvalidResolver();
        if (feedId0_ == bytes32(0) || feedId1_ == bytes32(0)) revert InvalidFeedId();
        resolver = resolver_;
        feedId0 = feedId0_;
        feedId1 = feedId1_;
    }

    function readPrice() public view override returns (Price memory result) {
        bytes32[] memory ids = new bytes32[](2);
        ids[0] = feedId0;
        ids[1] = feedId1;
        IMarketPriceResolverV3.PriceBatch memory prices = resolver.getPrices(ids);
        if (
            prices.values.length != 2 || prices.canonicalEpoch == 0 || prices.observedAt == 0
                || prices.observedAt > block.timestamp || prices.validUntil < prices.observedAt
                || block.timestamp > prices.validUntil
        ) revert InvalidSnapshot();
        (result.numerator, result.denominator) = PriceRatioMath.scale(
            prices.values[0], prices.values[1], int256(uint256(decimals1)) - int256(uint256(decimals0))
        );
        result.observedAt = prices.observedAt;
        result.validUntil = prices.validUntil;
        result.updateId = bytes32(uint256(prices.canonicalEpoch));
    }
}
