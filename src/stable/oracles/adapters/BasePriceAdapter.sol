// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IPriceAdapter} from "../interfaces/IPriceAdapter.sol";
import {PriceRatioMath} from "../libraries/PriceRatioMath.sol";

abstract contract BasePriceAdapter is IPriceAdapter {
    address public immutable override token0;
    address public immutable override token1;
    uint8 public immutable decimals0;
    uint8 public immutable decimals1;
    error InvalidTokenOrder();

    /// @dev Metadata is read once; token decimals must remain stable. Native currency is unsupported.
    constructor(address token0_, address token1_) {
        if (token0_ == address(0) || token0_ >= token1_) revert InvalidTokenOrder();
        uint8 d0 = IERC20Metadata(token0_).decimals();
        uint8 d1 = IERC20Metadata(token1_).decimals();
        if (d0 > PriceRatioMath.MAX_TOKEN_DECIMALS) revert PriceRatioMath.UnsupportedDecimals(d0);
        if (d1 > PriceRatioMath.MAX_TOKEN_DECIMALS) revert PriceRatioMath.UnsupportedDecimals(d1);
        token0 = token0_;
        token1 = token1_;
        decimals0 = d0;
        decimals1 = d1;
    }
}
