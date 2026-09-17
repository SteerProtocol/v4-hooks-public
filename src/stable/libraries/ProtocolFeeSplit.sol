// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {ProtocolFeeLibrary} from "@uniswap/v4-core/src/libraries/ProtocolFeeLibrary.sol";

/// @notice Split an existing fee budget; never add a treasury surcharge.
library ProtocolFeeSplit {
    uint256 internal constant PIPS = 1_000_000;

    struct Quote {
        uint24 lpFeePips;
        uint24 totalSwapFeePips;
        uint24 poolSwapFeePips;
    }

    /// @dev Inputs are validated by the hook/core. Native Uniswap fees remain controlled by core.
    ///      Rounding the remaining pool fee up ensures the treasury fraction cannot exceed its budget.
    function quote(uint24 fee, uint16 nativeFee, uint16 shareBps, uint24 capPips)
        internal
        pure
        returns (Quote memory q)
    {
        q.totalSwapFeePips = ProtocolFeeLibrary.calculateSwapFee(nativeFee, fee);
        q.lpFeePips = fee;
        q.poolSwapFeePips = q.totalSwapFeePips;
        uint256 budget = uint256(fee) * shareBps / 10_000;
        if (budget > capPips) budget = capPips;
        // A saturated core fee cannot be split with the exact-output denominator below.
        if (budget == 0 || q.totalSwapFeePips == PIPS) return q;
        uint256 requiredPoolFee = FullMath.mulDivRoundingUp(PIPS, q.totalSwapFeePips - budget, PIPS - budget);
        if (requiredPoolFee <= nativeFee) {
            q.lpFeePips = 0;
        } else {
            // Minimal integer LP fee whose rounded-up core aggregate reaches requiredPoolFee.
            q.lpFeePips = uint24((requiredPoolFee - nativeFee - 1) * PIPS / (PIPS - nativeFee) + 1);
        }
        q.poolSwapFeePips = ProtocolFeeLibrary.calculateSwapFee(nativeFee, q.lpFeePips);
    }

    /// @notice Treasury amount deducted from a fully consumed exact-input budget.
    function exactInput(uint256 grossInput, Quote memory q) internal pure returns (uint256) {
        if (q.totalSwapFeePips == q.poolSwapFeePips) return 0;
        return FullMath.mulDiv(grossInput, q.totalSwapFeePips - q.poolSwapFeePips, PIPS - q.poolSwapFeePips);
    }

    /// @notice Treasury amount added to actual pool input for an exact-output swap.
    function exactOutput(uint256 poolInput, Quote memory q) internal pure returns (uint256) {
        if (q.totalSwapFeePips == q.poolSwapFeePips) return 0;
        return FullMath.mulDiv(poolInput, q.totalSwapFeePips - q.poolSwapFeePips, PIPS - q.totalSwapFeePips);
    }
}
