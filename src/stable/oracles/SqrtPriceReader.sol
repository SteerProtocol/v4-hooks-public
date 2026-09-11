// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPriceAdapter} from "./interfaces/IPriceAdapter.sol";
import {PriceRatioMath} from "./libraries/PriceRatioMath.sol";

/// @notice Provider-independent conversion from a price adapter to a v4 reference sqrt price.
contract SqrtPriceReader {
    struct ReferencePrice {
        uint160 sqrtPriceX96;
        uint64 observedAt;
        uint64 validUntil;
        bytes32 updateId;
    }

    IPriceAdapter public immutable adapter;
    address public immutable token0;
    address public immutable token1;
    error InvalidAdapter();
    error InvalidMetadata();

    constructor(IPriceAdapter adapter_) {
        if (address(adapter_).code.length == 0) revert InvalidAdapter();
        address t0 = adapter_.token0();
        address t1 = adapter_.token1();
        if (t0 == address(0) || t0 >= t1) revert InvalidAdapter();
        adapter = adapter_;
        token0 = t0;
        token1 = t1;
    }

    /// @dev Zero timestamps mean unavailable metadata, as with ERC-7726. Never interpreted as fresh now.
    ///      Adapters must enforce their documented source-specific validity policy.
    function read() external view returns (ReferencePrice memory result) {
        IPriceAdapter.Price memory price = adapter.readPrice();
        if (price.observedAt != 0 || price.validUntil != 0) {
            if (
                price.observedAt == 0 || price.observedAt > block.timestamp || price.validUntil < price.observedAt
                    || block.timestamp > price.validUntil
            ) revert InvalidMetadata();
        }
        result = ReferencePrice(
            PriceRatioMath.toSqrtPriceX96(price.numerator, price.denominator),
            price.observedAt,
            price.validUntil,
            price.updateId
        );
    }
}
