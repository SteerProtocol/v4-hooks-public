// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PriceRatioMath} from "../../../src/stable/oracles/libraries/PriceRatioMath.sol";

contract PriceRatioMathTest is Test {
    function convert(uint256 n, uint256 d) external pure returns (uint160) {
        return PriceRatioMath.toSqrtPriceX96(n, d);
    }

    function scale(uint256 n, uint256 d, int256 e) external pure returns (uint256, uint256) {
        return PriceRatioMath.scale(n, d, e);
    }

    function test_scaleCancelsBeforeMultiplication() public pure {
        (uint256 n, uint256 d) = PriceRatioMath.scale(type(uint256).max, type(uint256).max, 38);
        assertEq(n, 1e38);
        assertEq(d, 1);
        (n, d) = PriceRatioMath.scale(1, 1e38, 38);
        assertEq(n, 1);
        assertEq(d, 1);
        (n, d) = PriceRatioMath.scale(1e38, 1, -38);
        assertEq(n, 1);
        assertEq(d, 1);
        (n, d) = PriceRatioMath.scale(200e18, 1e8, -22);
        assertEq(n, 1);
        assertEq(d, 5e9);
    }

    function test_rejectsUnrepresentableScalingAndZeroComponents() public {
        vm.expectRevert(PriceRatioMath.RatioOverflow.selector);
        this.scale(type(uint256).max, 1, 1);
        vm.expectRevert(PriceRatioMath.RatioOverflow.selector);
        this.scale(1, type(uint256).max, -1);
        vm.expectRevert(PriceRatioMath.UnsupportedScale.selector);
        this.scale(1, 1, 78);
        vm.expectRevert(PriceRatioMath.UnsupportedScale.selector);
        this.scale(1, 1, -78);
        vm.expectRevert(PriceRatioMath.ZeroPrice.selector);
        this.convert(1, 0);
        vm.expectRevert(PriceRatioMath.ZeroPrice.selector);
        this.scale(0, 1, 0);
    }

    /// @dev Independent Python math.isqrt constants, including 256-bit inputs.
    function test_fullWidthIntegerVectors() public pure {
        assertEq(
            PriceRatioMath.toSqrtPriceX96(
                115792089237316195423570985008687907853269984665640564039457584007913129639935,
                115792089237316195423570985008687907853269984665640564039457584007913129639934
            ),
            79228162514264337593543950336
        );
        assertEq(
            PriceRatioMath.toSqrtPriceX96(
                115792089237316195423570985008687907853269984665640564039457584007913129639935,
                6277101735386680763835789423207666416102355444464034512895
            ),
            340282366920938463463374607431768211456
        );
        assertEq(
            PriceRatioMath.toSqrtPriceX96(
                6277101735386680763835789423207666416102355444464034512895, 340282366920938463463374607431768211455
            ),
            340282366920938463463374607431768211456
        );
        assertEq(
            PriceRatioMath.toSqrtPriceX96(
                115792089237316195423570985008687907853269984665640564039457584007913129639935,
                12554203470773361527671578846415332832204710888928069025792
            ),
            240615969168004511545033772477625056927
        );
        assertEq(
            PriceRatioMath.toSqrtPriceX96(
                115792089237316195423570985008687907853269984665640564039457584007913129639935,
                1606938044258990275541962092341162602522202993782792835301376
            ),
            21267647932558653966460912964485513215
        );
        assertEq(
            PriceRatioMath.toSqrtPriceX96(
                1606938044258990275541962092341162602522202993782792835301499, 1267650600228229401496703205453
            ),
            89202980794122492566142873087884249373081600
        );
        assertEq(
            PriceRatioMath.toSqrtPriceX96(
                115792089237316195423570985008687907853269984665640564039457584007913129639836,
                680564733841876926926749214863536422915
            ),
            1033437718471923706666374484006904511249819347539
        );
    }

    function testFuzz_fullWidthRatio(uint256 n, uint256 d, uint8 nShift, uint8 dShift) public view {
        n >>= nShift;
        d >>= dShift;
        if (n == 0) n = 1;
        if (d == 0) d = 1;
        try this.convert(n, d) returns (uint160 root) {
            assertTrue(rootFits(n, d, root), "root rounded upward");
            assertFalse(rootFits(n, d, uint256(root) + 1), "root not exact floor");
        } catch (bytes memory reason) {
            assertEq(bytes4(reason), PriceRatioMath.SqrtPriceOutOfBounds.selector);
            assertTrue(!rootFits(n, d, TickMath.MIN_SQRT_PRICE) || rootFits(n, d, TickMath.MAX_SQRT_PRICE));
        }
    }

    /// @dev Independent 768-bit cross multiplication: candidate**2 * d <= n * 2**192.
    function rootFits(uint256 n, uint256 d, uint256 candidate) internal pure returns (bool) {
        (uint256 squareHi, uint256 squareLo) = mul512(candidate, candidate);
        (uint256 middle, uint256 low) = mul512(squareLo, d);
        (uint256 high, uint256 addend) = mul512(squareHi, d);
        unchecked {
            uint256 sum = middle + addend;
            if (sum < middle) ++high;
            if (high != 0) return false;
            uint256 rhsHi = n >> 64;
            uint256 rhsLo = n << 192;
            return sum < rhsHi || (sum == rhsHi && low <= rhsLo);
        }
    }

    function mul512(uint256 a, uint256 b) internal pure returns (uint256 hi, uint256 lo) {
        assembly ("memory-safe") {
            let mm := mulmod(a, b, not(0))
            lo := mul(a, b)
            hi := sub(sub(mm, lo), lt(mm, lo))
        }
    }
}
