// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ProtocolFeeSplit} from "../../src/stable/libraries/ProtocolFeeSplit.sol";

contract ProtocolFeeSplitTest is Test {
    function testFuzz_shareAndCapNeverExceeded(uint24 fee, uint16 nativeFee, uint16 share, uint24 cap, uint96 input)
        public
    {
        fee = uint24(bound(fee, 0, 999999));
        nativeFee = uint16(bound(nativeFee, 0, 1000));
        share = uint16(bound(share, 0, 10000));
        cap = uint24(bound(cap, 0, 999999));
        ProtocolFeeSplit.Quote memory q = ProtocolFeeSplit.quote(fee, nativeFee, share, cap);
        uint256 budget = uint256(fee) * share / 10000;
        if (budget > cap) budget = cap;
        assertLe(q.lpFeePips, fee);
        assertLe(q.poolSwapFeePips, q.totalSwapFeePips);
        uint256 beforeFee = ProtocolFeeSplit.exactInput(input, q);
        uint256 afterFee = ProtocolFeeSplit.exactOutput(input, q);
        assertLe(beforeFee * 1e6, uint256(input) * budget);
        assertLe(afterFee * 1e6, (uint256(input) + afterFee) * budget);
        // No surcharge: after rounding, effective net input is never smaller than the original fee budget.
        assertGe((uint256(input) - beforeFee) * (1e6 - q.poolSwapFeePips), uint256(input) * (1e6 - q.totalSwapFeePips));
        assertLe((uint256(input) + afterFee) * (1e6 - q.totalSwapFeePips), uint256(input) * (1e6 - q.poolSwapFeePips));
    }

    function test_zeroFeeZeroShareZeroCapAndSaturation() public pure {
        assertEq(ProtocolFeeSplit.exactInput(1e18, ProtocolFeeSplit.quote(0, 1000, 1000, 100)), 0);
        assertEq(ProtocolFeeSplit.exactInput(1e18, ProtocolFeeSplit.quote(1000, 0, 0, 100)), 0);
        assertEq(ProtocolFeeSplit.exactInput(1e18, ProtocolFeeSplit.quote(1000, 0, 1000, 0)), 0);
        assertEq(ProtocolFeeSplit.exactOutput(1e18, ProtocolFeeSplit.quote(1000000, 0, 1000, 100)), 0);
    }
}
