// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ChainlinkPriceAdapter} from "./ChainlinkPriceAdapter.sol";

interface IRobinhoodStockToken {
    function oraclePaused() external view returns (bool);
}

/// @notice Chainlink cross-price adapter with Robinhood's corporate-action pause guard.
/// @dev Official Robinhood feeds already include uiMultiplier. Never multiply the answer again.
///      Either or both currencies may be stock tokens, permitting stock/USDG and stock/stock pairs.
contract RobinhoodPriceAdapter is ChainlinkPriceAdapter {
    bool public immutable stock0;
    bool public immutable stock1;
    error StockOraclePaused(address token);

    constructor(address token0_, address token1_, Config memory config, bool stock0_, bool stock1_)
        ChainlinkPriceAdapter(token0_, token1_, config)
    {
        if (!stock0_ && !stock1_) revert InvalidConfiguration();
        stock0 = stock0_;
        stock1 = stock1_;
        _checkPause();
    }

    function readPrice() public view override returns (Price memory) {
        _checkPause();
        return super.readPrice();
    }

    function _checkPause() private view {
        if (stock0 && IRobinhoodStockToken(token0).oraclePaused()) revert StockOraclePaused(token0);
        if (stock1 && IRobinhoodStockToken(token1).oraclePaused()) revert StockOraclePaused(token1);
    }
}
