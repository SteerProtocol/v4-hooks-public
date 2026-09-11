// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IPriceAdapter} from "../../../src/stable/oracles/interfaces/IPriceAdapter.sol";
import {IAggregatorV3} from "../../../src/stable/oracles/interfaces/IAggregatorV3.sol";
import {IERC7726} from "../../../src/stable/oracles/interfaces/IERC7726.sol";
import {PriceRatioMath} from "../../../src/stable/oracles/libraries/PriceRatioMath.sol";
import {SqrtPriceReader} from "../../../src/stable/oracles/SqrtPriceReader.sol";
import {AtlasPriceAdapter} from "../../../src/stable/oracles/adapters/AtlasPriceAdapter.sol";
import {ChainlinkPriceAdapter} from "../../../src/stable/oracles/adapters/ChainlinkPriceAdapter.sol";
import {ERC7726PriceAdapter} from "../../../src/stable/oracles/adapters/ERC7726PriceAdapter.sol";
import {MockAtlasResolver} from "./AtlasSqrtPriceReader.t.sol";

contract MockAggregator is IAggregatorV3 {
    uint8 public decimals;
    uint80 public roundId = 1;
    int256 public answer;
    uint256 public startedAt;
    uint256 public updatedAt;
    bool public unavailable;
    error Unavailable();

    constructor(uint8 decimals_) {
        decimals = decimals_;
    }

    function setDecimals(uint8 value) external {
        decimals = value;
    }

    function set(uint80 round, int256 value, uint256 started, uint256 updated) external {
        roundId = round;
        answer = value;
        startedAt = started;
        updatedAt = updated;
    }

    function setUnavailable(bool value) external {
        unavailable = value;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        if (unavailable) revert Unavailable();
        // Zero answeredInRound exercises modern feeds that do not use the deprecated field.
        return (roundId, answer, startedAt, updatedAt, 0);
    }
}

contract MockQuoteOracle is IERC7726 {
    uint256 public amount = 200e6;
    bool public unavailable;
    error Unavailable();

    function set(uint256 value, bool failure) external {
        amount = value;
        unavailable = failure;
    }

    function getQuote(uint256 baseAmount, address base, address quote) external view returns (uint256) {
        if (unavailable) revert Unavailable();
        require(baseAmount == 1e18 && base == address(0x1000) && quote == address(0x2000), "quote arguments");
        return amount;
    }
}

contract MockPriceAdapter is IPriceAdapter {
    address public token0 = address(0x1000);
    address public token1 = address(0x2000);
    Price internal price;

    function set(Price memory value) external {
        price = value;
    }

    function setTokens(address t0, address t1) external {
        token0 = t0;
        token1 = t1;
    }

    function readPrice() external view returns (Price memory) {
        return price;
    }
}

contract PriceAdaptersTest is Test {
    address internal constant TOKEN0 = address(0x1000);
    address internal constant TOKEN1 = address(0x2000);
    uint160 internal constant EXPECTED = 1120455419495722798374638;
    MockAggregator internal feed0;
    MockAggregator internal feed1;
    ChainlinkPriceAdapter internal chainlink;
    SqrtPriceReader internal reader;

    function setUp() public {
        vm.warp(1000);
        vm.mockCall(TOKEN0, abi.encodeCall(IERC20Metadata.decimals, ()), abi.encode(uint8(18)));
        vm.mockCall(TOKEN1, abi.encodeCall(IERC20Metadata.decimals, ()), abi.encode(uint8(6)));
        feed0 = new MockAggregator(18);
        feed1 = new MockAggregator(8);
        feed0.set(10, 200e18, 900, 900);
        feed1.set(20, 1e8, 950, 950);
        chainlink = new ChainlinkPriceAdapter(TOKEN0, TOKEN1, config());
        reader = new SqrtPriceReader(chainlink);
    }

    function config() internal view returns (ChainlinkPriceAdapter.Config memory) {
        return ChainlinkPriceAdapter.Config(feed0, feed1, 300, 200, 100, IAggregatorV3(address(0)), 0);
    }

    function test_allAdaptersProduceSameSqrtPriceForSameMarket() public {
        MockAtlasResolver atlas = new MockAtlasResolver();
        uint64[] memory values = new uint64[](2);
        values[0] = 200e8;
        values[1] = 1e8;
        atlas.setSnapshot(7, 990, 1100, values);
        AtlasPriceAdapter atlasAdapter =
            new AtlasPriceAdapter(atlas, TOKEN0, TOKEN1, keccak256("token0/USD"), keccak256("token1/USD"));
        SqrtPriceReader atlasReader = new SqrtPriceReader(atlasAdapter);
        ERC7726PriceAdapter quoteAdapter = new ERC7726PriceAdapter(new MockQuoteOracle(), TOKEN0, TOKEN1, 1e18);
        SqrtPriceReader quoteReader = new SqrtPriceReader(quoteAdapter);
        assertEq(reader.read().sqrtPriceX96, EXPECTED);
        assertEq(atlasReader.read().sqrtPriceX96, EXPECTED);
        assertEq(quoteReader.read().sqrtPriceX96, EXPECTED);
        assertEq(atlasReader.read().updateId, bytes32(uint256(7)));
        assertEq(atlasReader.read().observedAt, 990);
        assertEq(atlasReader.read().validUntil, 1100);
        assertEq(quoteReader.read().observedAt, 0);
        assertEq(quoteReader.read().validUntil, 0);
        assertEq(quoteReader.read().updateId, bytes32(0));
    }

    function test_chainlinkMixedDecimalsAndConservativeMetadata() public view {
        SqrtPriceReader.ReferencePrice memory result = reader.read();
        assertEq(result.sqrtPriceX96, EXPECTED);
        assertEq(result.observedAt, 900);
        assertEq(result.validUntil, 1150);
        assertEq(result.updateId, keccak256(abi.encode(uint80(10), uint80(20))));
    }

    function test_chainlinkReversedStockOrientation() public {
        vm.mockCall(TOKEN0, abi.encodeCall(IERC20Metadata.decimals, ()), abi.encode(uint8(6)));
        vm.mockCall(TOKEN1, abi.encodeCall(IERC20Metadata.decimals, ()), abi.encode(uint8(18)));
        ChainlinkPriceAdapter.Config memory cfg = config();
        cfg.feed0 = feed1;
        cfg.feed1 = feed0;
        SqrtPriceReader inverse = new SqrtPriceReader(new ChainlinkPriceAdapter(TOKEN0, TOKEN1, cfg));
        assertEq(inverse.read().sqrtPriceX96, 5602277097478613991873193822745817);
    }

    function test_chainlinkHandlesQuoteDepegAndNewRound() public {
        feed1.set(21, 98e6, 950, 950);
        assertGt(reader.read().sqrtPriceX96, EXPECTED);
        assertEq(reader.read().updateId, keccak256(abi.encode(uint80(10), uint80(21))));
    }

    function test_chainlinkReadsFeedDecimalsRatherThanAssumingEight() public {
        feed0.setDecimals(8);
        feed0.set(11, 200e8, 900, 900);
        assertEq(reader.read().sqrtPriceX96, EXPECTED);
    }

    function test_chainlinkAcceptsAgeBoundaryThenRejectsStaleQuote() public {
        vm.warp(1150);
        reader.read();
        vm.warp(1151);
        vm.expectRevert(abi.encodeWithSelector(ChainlinkPriceAdapter.InvalidFeed.selector, address(feed1)));
        reader.read();
    }

    function test_chainlinkRejectsInvalidAnswersRoundsAndTimes() public {
        int256[5] memory answers = [int256(0), -1, 200e18, 200e18, 200e18];
        uint80[5] memory rounds = [uint80(10), 10, 0, 10, 10];
        uint256[5] memory times = [uint256(900), 900, 900, 0, 1001];
        for (uint256 i; i < 5; ++i) {
            feed0.set(rounds[i], answers[i], 900, times[i]);
            vm.expectRevert(abi.encodeWithSelector(ChainlinkPriceAdapter.InvalidFeed.selector, address(feed0)));
            reader.read();
        }
    }

    function test_chainlinkRejectsIndividuallyFreshButSkewedFeeds() public {
        feed1.set(20, 1e8, 1000, 1000);
        reader.read(); // Exact allowed skew: 100 seconds.
        feed0.set(10, 200e18, 899, 899);
        vm.expectRevert(ChainlinkPriceAdapter.FeedTimestampSkew.selector);
        reader.read();
    }

    function test_chainlinkPropagatesFeedFailure() public {
        feed0.setUnavailable(true);
        vm.expectRevert(MockAggregator.Unavailable.selector);
        reader.read();
    }

    function test_chainlinkRejectsUnsupportedFeedDecimals() public {
        feed1.setDecimals(39);
        vm.expectRevert(abi.encodeWithSelector(PriceRatioMath.UnsupportedDecimals.selector, uint8(39)));
        reader.read();
    }

    function test_chainlinkRejectsInvalidConfiguration() public {
        ChainlinkPriceAdapter.Config memory cfg = config();
        cfg.maxAge0 = 0;
        vm.expectRevert(ChainlinkPriceAdapter.InvalidConfiguration.selector);
        new ChainlinkPriceAdapter(TOKEN0, TOKEN1, cfg);
        cfg = config();
        cfg.feed1 = IAggregatorV3(address(0));
        vm.expectRevert(ChainlinkPriceAdapter.InvalidConfiguration.selector);
        new ChainlinkPriceAdapter(TOKEN0, TOKEN1, cfg);
        cfg = config();
        cfg.sequencerGracePeriod = 10;
        vm.expectRevert(ChainlinkPriceAdapter.InvalidConfiguration.selector);
        new ChainlinkPriceAdapter(TOKEN0, TOKEN1, cfg);
    }

    function test_chainlinkSequencerDowntimeAndRecoveryGrace() public {
        MockAggregator sequencer = new MockAggregator(0);
        ChainlinkPriceAdapter.Config memory cfg = config();
        cfg.sequencerUptimeFeed = sequencer;
        cfg.sequencerGracePeriod = 60;
        SqrtPriceReader guarded = new SqrtPriceReader(new ChainlinkPriceAdapter(TOKEN0, TOKEN1, cfg));
        sequencer.set(1, 1, 500, 500);
        vm.expectRevert(ChainlinkPriceAdapter.SequencerUnavailable.selector);
        guarded.read();
        sequencer.set(2, 0, 940, 940);
        vm.expectRevert(ChainlinkPriceAdapter.SequencerUnavailable.selector);
        guarded.read();
        sequencer.set(2, 0, 939, 939);
        assertEq(guarded.read().sqrtPriceX96, EXPECTED);
        sequencer.set(3, 0, 0, 0);
        vm.expectRevert(ChainlinkPriceAdapter.SequencerUnavailable.selector);
        guarded.read();
        sequencer.set(4, 0, 1001, 1001);
        vm.expectRevert(ChainlinkPriceAdapter.SequencerUnavailable.selector);
        guarded.read();
    }

    function test_erc7726ZeroQuoteAndSourceFailure() public {
        MockQuoteOracle oracle = new MockQuoteOracle();
        SqrtPriceReader quoteReader = new SqrtPriceReader(new ERC7726PriceAdapter(oracle, TOKEN0, TOKEN1, 1e18));
        oracle.set(0, false);
        vm.expectRevert(ERC7726PriceAdapter.ZeroQuote.selector);
        quoteReader.read();
        oracle.set(200e6, true);
        vm.expectRevert(MockQuoteOracle.Unavailable.selector);
        quoteReader.read();
    }

    function test_erc7726UsesReturnedRawAmountsWithoutRescaling() public {
        MockQuoteOracle oracle = new MockQuoteOracle();
        oracle.set(205e6, false);
        ERC7726PriceAdapter adapter = new ERC7726PriceAdapter(oracle, TOKEN0, TOKEN1, 1e18);
        IPriceAdapter.Price memory result = adapter.readPrice();
        assertEq(result.numerator, 205e6);
        assertEq(result.denominator, 1e18);
        assertEq(new SqrtPriceReader(adapter).read().sqrtPriceX96, PriceRatioMath.toSqrtPriceX96(205e6, 1e18));
    }

    function test_erc7726RejectsMissingOracleAndZeroSample() public {
        vm.expectRevert(ERC7726PriceAdapter.InvalidOracle.selector);
        new ERC7726PriceAdapter(IERC7726(address(0)), TOKEN0, TOKEN1, 1e18);
        MockQuoteOracle oracle = new MockQuoteOracle();
        vm.expectRevert(ERC7726PriceAdapter.InvalidBaseAmount.selector);
        new ERC7726PriceAdapter(oracle, TOKEN0, TOKEN1, 0);
    }

    function test_readerRejectsMissingOrUnorderedAdapter() public {
        vm.expectRevert(SqrtPriceReader.InvalidAdapter.selector);
        new SqrtPriceReader(IPriceAdapter(address(0)));
        MockPriceAdapter adapter = new MockPriceAdapter();
        adapter.setTokens(TOKEN1, TOKEN0);
        vm.expectRevert(SqrtPriceReader.InvalidAdapter.selector);
        new SqrtPriceReader(adapter);
    }

    function test_readerRejectsMalformedMetadataRatherThanTreatingItAsUnknown() public {
        MockPriceAdapter adapter = new MockPriceAdapter();
        SqrtPriceReader other = new SqrtPriceReader(adapter);
        adapter.set(IPriceAdapter.Price(1, 1, 990, 0, bytes32(0)));
        vm.expectRevert(SqrtPriceReader.InvalidMetadata.selector);
        other.read();
        adapter.set(IPriceAdapter.Price(1, 1, 0, 1100, bytes32(0)));
        vm.expectRevert(SqrtPriceReader.InvalidMetadata.selector);
        other.read();
        adapter.set(IPriceAdapter.Price(1, 1, 990, 999, bytes32(0)));
        vm.expectRevert(SqrtPriceReader.InvalidMetadata.selector);
        other.read();
    }
}
