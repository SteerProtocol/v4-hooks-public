// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BasePriceAdapter} from "./BasePriceAdapter.sol";
import {IAggregatorV3} from "../interfaces/IAggregatorV3.sol";
import {PriceRatioMath} from "../libraries/PriceRatioMath.sol";

/// @notice Cross-price two positive Chainlink feeds quoted in the same denomination.
/// @dev Configure proxy addresses and feed-specific heartbeat tolerances. No implicit stablecoin peg.
contract ChainlinkPriceAdapter is BasePriceAdapter {
    struct Config {
        IAggregatorV3 feed0;
        IAggregatorV3 feed1;
        uint32 maxAge0;
        uint32 maxAge1;
        uint32 maxTimestampSkew;
        // Optional on L1; configure the network's uptime feed and recovery grace period on supported L2s.
        IAggregatorV3 sequencerUptimeFeed;
        uint32 sequencerGracePeriod;
    }

    struct FeedPrice {
        uint256 value;
        uint64 updatedAt;
        uint64 validUntil;
        uint80 roundId;
        uint8 decimals;
    }

    IAggregatorV3 public immutable feed0;
    IAggregatorV3 public immutable feed1;
    uint32 public immutable maxAge0;
    uint32 public immutable maxAge1;
    uint32 public immutable maxTimestampSkew;
    IAggregatorV3 public immutable sequencerUptimeFeed;
    uint32 public immutable sequencerGracePeriod;
    error InvalidConfiguration();
    error InvalidFeed(address feed);
    error FeedTimestampSkew();
    error SequencerUnavailable();

    constructor(address token0_, address token1_, Config memory config) BasePriceAdapter(token0_, token1_) {
        if (
            address(config.feed0).code.length == 0 || address(config.feed1).code.length == 0 || config.maxAge0 == 0
                || config.maxAge1 == 0
        ) revert InvalidConfiguration();
        if (address(config.sequencerUptimeFeed) == address(0)) {
            if (config.sequencerGracePeriod != 0) revert InvalidConfiguration();
        } else if (address(config.sequencerUptimeFeed).code.length == 0 || config.sequencerGracePeriod == 0) {
            revert InvalidConfiguration();
        }
        feed0 = config.feed0;
        feed1 = config.feed1;
        maxAge0 = config.maxAge0;
        maxAge1 = config.maxAge1;
        maxTimestampSkew = config.maxTimestampSkew;
        sequencerUptimeFeed = config.sequencerUptimeFeed;
        sequencerGracePeriod = config.sequencerGracePeriod;
    }

    function readPrice() public view virtual override returns (Price memory result) {
        _checkSequencer();
        FeedPrice memory p0 = _readFeed(feed0, maxAge0);
        FeedPrice memory p1 = _readFeed(feed1, maxAge1);
        uint64 older = p0.updatedAt < p1.updatedAt ? p0.updatedAt : p1.updatedAt;
        uint64 newer = p0.updatedAt > p1.updatedAt ? p0.updatedAt : p1.updatedAt;
        if (newer - older > maxTimestampSkew) revert FeedTimestampSkew();
        // Raw token1/token0 = answer0/answer1 * 10^(feedDecimals1-feedDecimals0+tokenDecimals1-tokenDecimals0).
        int256 exponent = int256(uint256(p1.decimals)) - int256(uint256(p0.decimals)) + int256(uint256(decimals1))
            - int256(uint256(decimals0));
        (result.numerator, result.denominator) = PriceRatioMath.scale(p0.value, p1.value, exponent);
        result.observedAt = older;
        result.validUntil = p0.validUntil < p1.validUntil ? p0.validUntil : p1.validUntil;
        result.updateId = keccak256(abi.encode(p0.roundId, p1.roundId));
    }

    function _readFeed(IAggregatorV3 feed, uint32 maxAge) private view returns (FeedPrice memory result) {
        (uint80 roundId, int256 answer,, uint256 updatedAt,) = feed.latestRoundData();
        // answeredInRound is deprecated in AggregatorV3; validity uses answer, roundId and updatedAt.
        if (
            roundId == 0 || answer <= 0 || updatedAt == 0 || updatedAt > block.timestamp
                || updatedAt > type(uint64).max - uint256(maxAge) || block.timestamp - updatedAt > maxAge
        ) revert InvalidFeed(address(feed));
        uint8 feedDecimals = feed.decimals();
        if (feedDecimals > 38) revert PriceRatioMath.UnsupportedDecimals(feedDecimals);
        result = FeedPrice(uint256(answer), uint64(updatedAt), uint64(updatedAt + maxAge), roundId, feedDecimals);
    }

    function _checkSequencer() private view {
        if (address(sequencerUptimeFeed) == address(0)) return;
        (, int256 answer, uint256 startedAt,,) = sequencerUptimeFeed.latestRoundData();
        if (
            answer != 0 || startedAt == 0 || startedAt > block.timestamp
                || block.timestamp - startedAt <= sequencerGracePeriod
        ) revert SequencerUnavailable();
    }
}
