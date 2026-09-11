// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {AtlasPriceAdapter} from "./adapters/AtlasPriceAdapter.sol";
import {IMarketPriceResolverV3} from "./interfaces/IMarketPriceResolverV3.sol";
import {PriceRatioMath} from "./libraries/PriceRatioMath.sol";

/// @notice Compatibility convenience wrapper. New integrations can use AtlasPriceAdapter + SqrtPriceReader.
contract AtlasSqrtPriceReader is AtlasPriceAdapter {
    struct ReferencePrice {
        uint160 sqrtPriceX96;
        uint64 canonicalEpoch;
        uint64 observedAt;
        uint64 validUntil;
    }

    constructor(IMarketPriceResolverV3 resolver_, address token0_, address token1_, bytes32 feedId0_, bytes32 feedId1_)
        AtlasPriceAdapter(resolver_, token0_, token1_, feedId0_, feedId1_)
    {}

    function read() external view returns (ReferencePrice memory result) {
        Price memory price = readPrice();
        result = ReferencePrice(
            PriceRatioMath.toSqrtPriceX96(price.numerator, price.denominator),
            uint64(uint256(price.updateId)),
            price.observedAt,
            price.validUntil
        );
    }
}
