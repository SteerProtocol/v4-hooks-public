// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {OracleStablePairHook} from "./OracleStablePairHook.sol";
import {StableFeeConfig} from "./interfaces/IStableFeeConfiguration.sol";
import {SqrtPriceReader} from "./oracles/SqrtPriceReader.sol";
import {ProtocolFeeSplit} from "./libraries/ProtocolFeeSplit.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {ProtocolFeeLibrary} from "@uniswap/v4-core/src/libraries/ProtocolFeeLibrary.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";

/// @notice A capped treasury share of the oracle auction fee, collected as input-currency ERC6909 claims.
/// @dev Fee-bearing exact-input swaps must fill completely. Preview rates alone are not executable quotes:
///      simulate the actual swap, including its price limit, tick crossings and integer rounding.
contract ProtocolFeeOracleStablePairHook is OracleStablePairHook {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using CurrencyLibrary for Currency;
    using SafeCast for uint256;

    struct ProtocolFeeConfig {
        address recipient;
        uint16 protocolFeeShareBps;
        uint24 maxProtocolFeePips;
    }

    /// @custom:storage-location erc7201:steer.storage.ProtocolFeeOracleStablePairHook
    struct ProtocolStorage {
        mapping(PoolId => ProtocolFeeConfig) configs;
    }

    bytes32 private constant STORAGE_LOCATION = 0x92dbbaf3267dae2ff8915de5b7acc7c5b8a4d202f377f537b1eeec1dd7503000;
    bytes32 private constant SWAP_SLOT = keccak256("steer.protocolFee.swap.quote");

    error InvalidProtocolFeeConfig();
    error SwapAlreadyActive();
    error MissingSwapContext();
    error PartialExactInput(uint256 requestedInput, uint256 executableInput);
    error InvalidInputDelta();

    event ProtocolFeeConfigured(PoolId indexed poolId, address indexed recipient, uint16 shareBps, uint24 capPips);
    event ProtocolFeeAccrued(
        PoolId indexed poolId, address indexed recipient, Currency indexed currency, uint256 amount
    );

    constructor(IPoolManager manager) OracleStablePairHook(manager) {}

    function getHookPermissions() public pure override returns (Hooks.Permissions memory p) {
        p = super.getHookPermissions();
        p.beforeSwapReturnDelta = true;
        p.afterSwapReturnDelta = true;
    }

    /// @notice Initialize both policies atomically. Ordinary oracle initialization leaves treasury fees disabled.
    function initializeOraclePoolWithProtocolFee(
        PoolKey calldata key,
        StableFeeConfig memory config,
        SqrtPriceReader reader,
        ProtocolFeeConfig calldata treasury
    ) external returns (int24 tick) {
        tick = initializeOraclePool(key, config, reader);
        _configure(key.toId(), treasury);
    }

    /// @notice Does not reset or change the auction configuration/state.
    function setProtocolFeeConfig(PoolId id, ProtocolFeeConfig calldata config) external onlyRole(CONFIG_MANAGER_ROLE) {
        _checkPoolInitialized(id);
        _configure(id, config);
    }

    function protocolFeeConfig(PoolId id) public view returns (ProtocolFeeConfig memory) {
        return _protocolStorage().configs[id];
    }

    /// @notice getFee retains its original meaning: the unsplit auction fee, excluding native Uniswap fees.
    ///         This preview supplies the adjusted LP and aggregate rates for a direction, not a fill guarantee.
    function getFeeSplit(PoolKey calldata key, bool zeroForOne) external view returns (ProtocolFeeSplit.Quote memory) {
        (uint24 zero, uint24 one) = this.getFee(key);
        return _quote(key, zeroForOne, zeroForOne ? zero : one);
    }

    function _configure(PoolId id, ProtocolFeeConfig calldata c) private {
        if (
            c.protocolFeeShareBps > 10_000 || c.maxProtocolFeePips >= 1_000_000
                || (c.protocolFeeShareBps != 0
                    && c.maxProtocolFeePips != 0
                    && (c.recipient == address(0)
                        || c.recipient == address(this)
                        || c.recipient == address(poolManager)))
        ) {
            revert InvalidProtocolFeeConfig();
        }
        _protocolStorage().configs[id] = c;
        emit ProtocolFeeConfigured(id, c.recipient, c.protocolFeeShareBps, c.maxProtocolFeePips);
    }

    function _quote(PoolKey calldata key, bool zeroForOne, uint24 fee)
        private
        view
        returns (ProtocolFeeSplit.Quote memory)
    {
        ProtocolFeeConfig memory c = protocolFeeConfig(key.toId());
        (,, uint24 nativeFees,) = poolManager.getSlot0(key.toId());
        uint16 nativeFee = zeroForOne
            ? ProtocolFeeLibrary.getZeroForOneFee(nativeFees)
            : ProtocolFeeLibrary.getOneForZeroFee(nativeFees);
        return ProtocolFeeSplit.quote(fee, nativeFee, c.protocolFeeShareBps, c.maxProtocolFeePips);
    }

    function _beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata data)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        bytes32 slot = SWAP_SLOT;
        uint256 active;
        assembly ("memory-safe") { active := tload(slot) }
        if (active != 0) revert SwapAlreadyActive();
        (,, uint24 overrideFee) = super._beforeSwap(sender, key, params, data);
        ProtocolFeeSplit.Quote memory q = _quote(key, params.zeroForOne, overrideFee & ~LPFeeLibrary.OVERRIDE_FEE_FLAG);
        uint256 amount;
        if (params.amountSpecified < 0) {
            amount = ProtocolFeeSplit.exactInput(uint256(-params.amountSpecified), q);
            // No discount when integer rounding makes the treasury deduction zero.
            if (amount == 0) {
                q.poolSwapFeePips = q.totalSwapFeePips;
                q.lpFeePips = overrideFee & ~LPFeeLibrary.OVERRIDE_FEE_FLAG;
            }
        }
        uint256 packed = 1 | (uint256(q.totalSwapFeePips) << 8) | (uint256(q.poolSwapFeePips) << 32);
        assembly ("memory-safe") { tstore(slot, packed) }
        return (
            IHooks.beforeSwap.selector,
            toBeforeSwapDelta(amount.toInt128(), 0),
            q.lpFeePips | LPFeeLibrary.OVERRIDE_FEE_FLAG
        );
    }

    function _afterSwap(address, PoolKey calldata key, SwapParams calldata params, BalanceDelta delta, bytes calldata)
        internal
        override
        returns (bytes4, int128)
    {
        bytes32 slot = SWAP_SLOT;
        uint256 packed;
        assembly ("memory-safe") {
            packed := tload(slot)
            tstore(slot, 0)
        }
        if (packed == 0) revert MissingSwapContext();
        ProtocolFeeSplit.Quote memory q = ProtocolFeeSplit.Quote(0, uint24(packed >> 8), uint24(packed >> 32));
        int128 inputDelta = params.zeroForOne ? delta.amount0() : delta.amount1();
        if (inputDelta > 0) revert InvalidInputDelta();
        uint256 poolInput = uint256(-int256(inputDelta));
        uint256 amount;
        bool exactInput = params.amountSpecified < 0;
        if (exactInput) {
            uint256 gross = uint256(-params.amountSpecified);
            amount = ProtocolFeeSplit.exactInput(gross, q);
            if (amount != 0 && poolInput != gross - amount) {
                revert PartialExactInput(gross, poolInput + ProtocolFeeSplit.exactOutput(poolInput, q));
            }
        } else {
            amount = ProtocolFeeSplit.exactOutput(poolInput, q);
        }
        if (amount != 0) _accrue(key, params.zeroForOne, amount);
        return (IHooks.afterSwap.selector, exactInput ? int128(0) : amount.toInt128());
    }

    function _accrue(PoolKey calldata key, bool zeroForOne, uint256 amount) private {
        Currency input = zeroForOne ? key.currency0 : key.currency1;
        address recipient = protocolFeeConfig(key.toId()).recipient;
        poolManager.mint(recipient, input.toId(), amount);
        emit ProtocolFeeAccrued(key.toId(), recipient, input, amount);
    }

    function _protocolStorage() private pure returns (ProtocolStorage storage $) {
        assembly ("memory-safe") { $.slot := STORAGE_LOCATION }
    }
}
