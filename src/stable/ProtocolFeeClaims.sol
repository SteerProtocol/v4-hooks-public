// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";

/// @notice Redeem the caller's treasury claims, in batches, to that same caller.
/// @dev The caller must first approve this contract as a PoolManager ERC6909 operator.
///      No ERC20 approval is needed. This helper cannot redirect another holder's claims.
contract ProtocolFeeClaims is IUnlockCallback {
    using CurrencyLibrary for Currency;
    IPoolManager public immutable poolManager;
    error OnlyPoolManager();
    event ClaimsWithdrawn(address indexed owner, Currency indexed currency, uint256 amount);

    constructor(IPoolManager manager) {
        poolManager = manager;
    }

    function withdraw(Currency[] calldata currencies) external {
        poolManager.unlock(abi.encode(msg.sender, currencies));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert OnlyPoolManager();
        (address owner, Currency[] memory currencies) = abi.decode(data, (address, Currency[]));
        for (uint256 i; i < currencies.length; ++i) {
            Currency currency = currencies[i];
            uint256 amount = poolManager.balanceOf(owner, currency.toId());
            if (amount != 0) {
                poolManager.burn(owner, currency.toId(), amount);
                poolManager.take(currency, owner, amount);
                emit ClaimsWithdrawn(owner, currency, amount);
            }
        }
        return "";
    }
}
