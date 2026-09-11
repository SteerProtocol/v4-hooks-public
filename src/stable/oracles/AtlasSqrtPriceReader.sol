// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IMarketPriceResolverV3} from "./interfaces/IMarketPriceResolverV3.sol";
import {AtlasPriceMath} from "./libraries/AtlasPriceMath.sol";

/// @notice Read a pair's reference sqrtPriceX96 from Steer Atlas without changing hook state.
/// @dev One immutable reader per ordered ERC-20 pair. Feed values must price one whole token
///      in a common denomination. Does not assume a stablecoin peg or apply wrapper/share conversions.
contract AtlasSqrtPriceReader {
    struct ReferencePrice {
        uint160 sqrtPriceX96;
        uint64 canonicalEpoch;
        uint64 observedAt;
        uint64 validUntil;
    }

    IMarketPriceResolverV3 public immutable resolver;
    address public immutable token0;
    address public immutable token1;
    bytes32 public immutable feedId0;
    bytes32 public immutable feedId1;
    uint8 public immutable decimals0;
    uint8 public immutable decimals1;

    error InvalidResolver();
    error InvalidTokenOrder();
    error InvalidFeedId();
    error InvalidSnapshot();

    /// @dev Token addresses must match v4 ordering. Native currency is unsupported; use wrapped tokens.
    ///      Decimals are queried once and must remain stable for the lifetime of this reader.
    constructor(
        IMarketPriceResolverV3 resolver_,
        address token0_,
        address token1_,
        bytes32 feedId0_,
        bytes32 feedId1_
    ) {
        if (address(resolver_).code.length == 0) revert InvalidResolver();
        if (token0_ == address(0) || token0_ >= token1_) revert InvalidTokenOrder();
        if (feedId0_ == bytes32(0) || feedId1_ == bytes32(0)) revert InvalidFeedId();

        uint8 d0 = IERC20Metadata(token0_).decimals();
        uint8 d1 = IERC20Metadata(token1_).decimals();
        if (d0 > AtlasPriceMath.MAX_TOKEN_DECIMALS) revert AtlasPriceMath.UnsupportedDecimals(d0);
        if (d1 > AtlasPriceMath.MAX_TOKEN_DECIMALS) revert AtlasPriceMath.UnsupportedDecimals(d1);

        resolver = resolver_;
        token0 = token0_;
        token1 = token1_;
        feedId0 = feedId0_;
        feedId1 = feedId1_;
        decimals0 = d0;
        decimals1 = d1;
    }

    /// @notice Return the latest valid reference and the Atlas snapshot that produced it.
    /// @dev Resolver failures propagate. There is no last-good-price cache or fallback.
    ///      A consumer may enforce a stricter maximum age than Atlas's validUntil policy.
    function read() external view returns (ReferencePrice memory result) {
        bytes32[] memory feedIds = new bytes32[](2);
        feedIds[0] = feedId0;
        feedIds[1] = feedId1;
        IMarketPriceResolverV3.PriceBatch memory prices = resolver.getPrices(feedIds);
        if (
            prices.values.length != 2 || prices.canonicalEpoch == 0 || prices.observedAt == 0
                || prices.observedAt > block.timestamp || prices.validUntil < prices.observedAt
                || block.timestamp > prices.validUntil
        ) revert InvalidSnapshot();

        result = ReferencePrice({
            sqrtPriceX96: AtlasPriceMath.toSqrtPriceX96(prices.values[0], prices.values[1], decimals0, decimals1),
            canonicalEpoch: prices.canonicalEpoch,
            observedAt: prices.observedAt,
            validUntil: prices.validUntil
        });
    }
}
