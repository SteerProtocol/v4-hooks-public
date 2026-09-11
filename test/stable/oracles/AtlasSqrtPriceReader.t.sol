// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {AtlasSqrtPriceReader} from "../../../src/stable/oracles/AtlasSqrtPriceReader.sol";
import {AtlasPriceMath} from "../../../src/stable/oracles/libraries/AtlasPriceMath.sol";
import {IMarketPriceResolverV3} from "../../../src/stable/oracles/interfaces/IMarketPriceResolverV3.sol";

contract MockAtlasResolver is IMarketPriceResolverV3 {
    bytes32 internal constant FEED0 = keccak256("token0/USD");
    bytes32 internal constant FEED1 = keccak256("token1/USD");
    PriceBatch internal snapshot;
    bool internal unavailable;
    error FeedUnavailable();

    function setSnapshot(uint64 epoch, uint64 observed, uint64 expiry, uint64[] memory values) external {
        snapshot = PriceBatch(epoch, observed, expiry, values);
    }

    function setUnavailable(bool value) external {
        unavailable = value;
    }

    function getPrices(bytes32[] calldata feedIds) external view returns (PriceBatch memory) {
        if (unavailable) revert FeedUnavailable();
        require(feedIds.length == 2 && feedIds[0] == FEED0 && feedIds[1] == FEED1, "feed mapping");
        return snapshot;
    }
}

contract AtlasSqrtPriceReaderTest is Test {
    address internal constant TOKEN0 = address(0x1000);
    address internal constant TOKEN1 = address(0x2000);
    bytes32 internal constant FEED0 = keccak256("token0/USD");
    bytes32 internal constant FEED1 = keccak256("token1/USD");
    MockAtlasResolver internal resolver;
    AtlasSqrtPriceReader internal reader;

    function setUp() public {
        vm.warp(1000);
        resolver = new MockAtlasResolver();
        reader = deployReader(18, 6);
        setSnapshot(7, 990, 1100, 200e8, 1e8);
    }

    function deployReader(uint8 d0, uint8 d1) internal returns (AtlasSqrtPriceReader) {
        vm.mockCall(TOKEN0, abi.encodeCall(IERC20Metadata.decimals, ()), abi.encode(d0));
        vm.mockCall(TOKEN1, abi.encodeCall(IERC20Metadata.decimals, ()), abi.encode(d1));
        return new AtlasSqrtPriceReader(resolver, TOKEN0, TOKEN1, FEED0, FEED1);
    }

    function setSnapshot(uint64 epoch, uint64 observed, uint64 expiry, uint64 p0, uint64 p1) internal {
        uint64[] memory values = new uint64[](2);
        values[0] = p0;
        values[1] = p1;
        resolver.setSnapshot(epoch, observed, expiry, values);
    }

    // External harness so vm.expectRevert observes conversion failures on a distinct call.
    function convert(uint64 p0, uint64 p1, uint8 d0, uint8 d1) external pure returns (uint160) {
        return AtlasPriceMath.toSqrtPriceX96(p0, p1, d0, d1);
    }

    function test_stockToken0ReturnsPriceAndSnapshot() public view {
        AtlasSqrtPriceReader.ReferencePrice memory result = reader.read();
        assertEq(result.sqrtPriceX96, 1120455419495722798374638);
        assertEq(result.canonicalEpoch, 7);
        assertEq(result.observedAt, 990);
        assertEq(result.validUntil, 1100);
        assertEq(reader.token0(), TOKEN0);
        assertEq(reader.token1(), TOKEN1);
        assertEq(reader.decimals0(), 18);
        assertEq(reader.decimals1(), 6);
    }

    function test_stockToken1InvertsPriceAndDecimals() public {
        reader = deployReader(6, 18);
        setSnapshot(7, 990, 1100, 1e8, 200e8);
        assertEq(reader.read().sqrtPriceX96, 5602277097478613991873193822745817);
    }

    function test_readsNewEpochWithoutAnUpdaterOrCachedFallback() public {
        uint160 beforePrice = reader.read().sqrtPriceX96;
        setSnapshot(8, 999, 1200, 205e8, 1e8);
        AtlasSqrtPriceReader.ReferencePrice memory result = reader.read();
        assertGt(result.sqrtPriceX96, beforePrice);
        assertEq(result.canonicalEpoch, 8);
        assertEq(result.observedAt, 999);
        assertEq(result.validUntil, 1200);
    }

    function test_quoteDepegIsIncludedInRatio() public {
        uint160 beforePrice = reader.read().sqrtPriceX96;
        setSnapshot(8, 999, 1200, 200e8, 98e6);
        assertGt(reader.read().sqrtPriceX96, beforePrice);
    }

    function test_acceptsExactExpiryThenRejectsExpiredData() public {
        vm.warp(1100);
        reader.read();
        vm.warp(1101);
        vm.expectRevert(AtlasSqrtPriceReader.InvalidSnapshot.selector);
        reader.read();
    }

    function test_rejectsInvalidSnapshotMetadata() public {
        uint64[4] memory epochs = [uint64(0), 7, 7, 7];
        uint64[4] memory observed = [uint64(990), 0, 1001, 990];
        uint64[4] memory expiry = [uint64(1100), 1100, 1100, 989];
        for (uint256 i; i < 4; ++i) {
            setSnapshot(epochs[i], observed[i], expiry[i], 200e8, 1e8);
            vm.expectRevert(AtlasSqrtPriceReader.InvalidSnapshot.selector);
            reader.read();
        }
    }

    function test_rejectsMalformedBatchLength() public {
        for (uint256 n; n < 4; ++n) {
            if (n == 2) continue;
            resolver.setSnapshot(7, 990, 1100, new uint64[](n));
            vm.expectRevert(AtlasSqrtPriceReader.InvalidSnapshot.selector);
            reader.read();
        }
    }

    function test_rejectsZeroPrices() public {
        setSnapshot(7, 990, 1100, 0, 1e8);
        vm.expectRevert(AtlasPriceMath.ZeroPrice.selector);
        reader.read();
        setSnapshot(7, 990, 1100, 200e8, 0);
        vm.expectRevert(AtlasPriceMath.ZeroPrice.selector);
        reader.read();
    }

    function test_propagatesAtlasReadFailure() public {
        resolver.setUnavailable(true);
        vm.expectRevert(MockAtlasResolver.FeedUnavailable.selector);
        reader.read();
    }

    function test_constructorRejectsMissingResolver() public {
        vm.expectRevert(AtlasSqrtPriceReader.InvalidResolver.selector);
        new AtlasSqrtPriceReader(IMarketPriceResolverV3(address(0)), TOKEN0, TOKEN1, FEED0, FEED1);
    }

    function test_constructorRejectsUnorderedOrNativeTokens() public {
        vm.expectRevert(AtlasSqrtPriceReader.InvalidTokenOrder.selector);
        new AtlasSqrtPriceReader(resolver, TOKEN1, TOKEN0, FEED0, FEED1);
        vm.expectRevert(AtlasSqrtPriceReader.InvalidTokenOrder.selector);
        new AtlasSqrtPriceReader(resolver, TOKEN0, TOKEN0, FEED0, FEED1);
        vm.expectRevert(AtlasSqrtPriceReader.InvalidTokenOrder.selector);
        new AtlasSqrtPriceReader(resolver, address(0), TOKEN1, FEED0, FEED1);
    }

    function test_constructorRejectsEmptyFeeds() public {
        vm.expectRevert(AtlasSqrtPriceReader.InvalidFeedId.selector);
        new AtlasSqrtPriceReader(resolver, TOKEN0, TOKEN1, bytes32(0), FEED1);
        vm.expectRevert(AtlasSqrtPriceReader.InvalidFeedId.selector);
        new AtlasSqrtPriceReader(resolver, TOKEN0, TOKEN1, FEED0, bytes32(0));
    }

    function test_constructorRejectsUnsupportedDecimals() public {
        vm.mockCall(TOKEN0, abi.encodeCall(IERC20Metadata.decimals, ()), abi.encode(uint8(39)));
        vm.expectRevert(abi.encodeWithSelector(AtlasPriceMath.UnsupportedDecimals.selector, uint8(39)));
        new AtlasSqrtPriceReader(resolver, TOKEN0, TOKEN1, FEED0, FEED1);
    }

    function test_rejectsOutOfV4Range() public {
        vm.expectRevert(AtlasPriceMath.SqrtPriceOutOfBounds.selector);
        this.convert(type(uint64).max, 1, 0, 38);
        vm.expectRevert(AtlasPriceMath.SqrtPriceOutOfBounds.selector);
        this.convert(1, type(uint64).max, 38, 0);
        // Values just outside v4's limits, even though within the mathematical Q96 range.
        vm.expectRevert(AtlasPriceMath.SqrtPriceOutOfBounds.selector);
        this.convert(1, 3_402_567_868_363_880_940, 20, 0);
        vm.expectRevert(AtlasPriceMath.SqrtPriceOutOfBounds.selector);
        this.convert(3_402_567_868_363_880_941, 1, 0, 20);
    }

    /// @dev Expected constants generated independently with Python math.isqrt on the exact rational.
    function test_exactIntegerVectors() public pure {
        assertEq(AtlasPriceMath.toSqrtPriceX96(20000000000, 100000000, 18, 6), 1120455419495722798374638);
        assertEq(AtlasPriceMath.toSqrtPriceX96(100000000, 20000000000, 6, 18), 5602277097478613991873193822745817);
        assertEq(AtlasPriceMath.toSqrtPriceX96(1, 1, 18, 18), 79228162514264337593543950336);
        assertEq(AtlasPriceMath.toSqrtPriceX96(20500000000, 98000000, 18, 6), 1145891443265571579326021);
        assertEq(AtlasPriceMath.toSqrtPriceX96(1, 1, 0, 38), 792281625142643375935439503360000000000000000000);
        assertEq(AtlasPriceMath.toSqrtPriceX96(1, 1, 38, 0), 7922816251);
        assertEq(AtlasPriceMath.toSqrtPriceX96(1844674407370955161, 1, 0, 1), 340282366920938463408034375210639556603);
        assertEq(AtlasPriceMath.toSqrtPriceX96(1844674407370955162, 1, 0, 1), 340282366920938463500268095579187314686);
        assertEq(
            AtlasPriceMath.toSqrtPriceX96(18446744073709551615, 1, 0, 18),
            340282366920938463454151235394913435647874999999
        );
        assertEq(AtlasPriceMath.toSqrtPriceX96(1, 18446744073709551615, 18, 0), 18446744073);
        assertEq(AtlasPriceMath.toSqrtPriceX96(9, 1, 0, 24), 237684487542793012780631851008000000000000);
        assertEq(AtlasPriceMath.toSqrtPriceX96(3, 1, 0, 24), 137227202865029797602485611888471561165793);
    }

    function testFuzz_exactFloor(uint64 p0, uint64 p1, uint8 d0, uint8 d1) public view {
        p0 = uint64(bound(p0, 1, type(uint64).max));
        p1 = uint64(bound(p1, 1, type(uint64).max));
        d0 = uint8(bound(d0, 0, 38));
        d1 = uint8(bound(d1, 0, 38));
        try this.convert(p0, p1, d0, d1) returns (uint160 root) {
            assertExactFloor(p0, p1, d0, d1, root);
        } catch (bytes memory reason) {
            assertEq(bytes4(reason), AtlasPriceMath.SqrtPriceOutOfBounds.selector);
            // Verify rejection against the v4 boundaries using division, not the sqrt implementation.
            (uint256 n, uint256 d) = ratio(p0, p1, d0, d1);
            bool below = n / d < (uint256(1) << 64)
                && FullMath.mulDiv(n, uint256(1) << 192, d) < uint256(TickMath.MIN_SQRT_PRICE) ** 2;
            bool above = n / d >= (uint256(1) << 128);
            if (!above && !below) {
                above = FullMath.mulDiv(n, uint256(1) << 192, d * uint256(TickMath.MAX_SQRT_PRICE))
                    >= TickMath.MAX_SQRT_PRICE;
            }
            assertTrue(below || above, "unexpected range rejection");
        }
    }

    function testFuzz_highRatioExactFloor(uint64 p0, uint64 p1) public pure {
        p0 = uint64(bound(p0, 1e8, 1e12));
        p1 = uint64(bound(p1, 1, 1e4));
        // Every ratio takes the high-precision branch while staying inside v4 bounds.
        uint160 root = AtlasPriceMath.toSqrtPriceX96(p0, p1, 0, 24);
        assertExactFloor(p0, p1, 0, 24, root);
    }

    function testFuzz_commonScaleDoesNotChangeRatio(uint32 p0, uint32 p1, uint16 scale) public pure {
        p0 = uint32(bound(p0, 1, type(uint32).max));
        p1 = uint32(bound(p1, 1, type(uint32).max));
        scale = uint16(bound(scale, 1, type(uint16).max));
        assertEq(
            AtlasPriceMath.toSqrtPriceX96(p0, p1, 18, 6),
            AtlasPriceMath.toSqrtPriceX96(uint64(p0) * scale, uint64(p1) * scale, 18, 6)
        );
    }

    function ratio(uint64 p0, uint64 p1, uint8 d0, uint8 d1) internal pure returns (uint256 n, uint256 d) {
        n = p0;
        d = p1;
        if (d1 >= d0) n *= 10 ** uint256(d1 - d0);
        else d *= 10 ** uint256(d0 - d1);
    }

    function assertExactFloor(uint64 p0, uint64 p1, uint8 d0, uint8 d1, uint160 root) internal pure {
        (uint256 n, uint256 d) = ratio(p0, p1, d0, d1);
        // Equivalent to root**2 <= n*2**192/d < (root+1)**2 without squaring a uint160.
        assertLe(root, FullMath.mulDiv(n, uint256(1) << 192, d * uint256(root)));
        assertGt(uint256(root) + 1, FullMath.mulDiv(n, uint256(1) << 192, d * (uint256(root) + 1)));
    }
}
