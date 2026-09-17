// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StablePairHook} from "./StablePairHook.sol";
import {StableFeeConfig, StableFeeState} from "./interfaces/IStableFeeConfiguration.sol";
import {StableFeeCalculation} from "./libraries/StableFeeCalculation.sol";
import {SqrtPriceReader} from "./oracles/SqrtPriceReader.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

/// @notice StablePair fee mechanics with a mandatory per-pool price reader.
/// @dev Reads on every preview/swap, including cached-price swaps. A changed reference price resets
///      the auction immediately, including within a block. Reader failures propagate; there is no
///      stored-price fallback. Frequent price changes can therefore repeatedly restart the auction.
contract OracleStablePairHook is StablePairHook {
    using PoolIdLibrary for PoolKey;

    /// @custom:storage-location erc7201:steer.storage.OracleStablePairHook
    struct OracleStorage {
        mapping(PoolId => SqrtPriceReader) readers;
    }

    // keccak256(abi.encode(uint256(keccak256("steer.storage.OracleStablePairHook")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant ORACLE_STORAGE_LOCATION =
        0xba5ca5e8ec7d68e5c5e55b39c2090e3b7086f815caade7078dcfc36e9b6e5200;

    error InvalidPriceReader();
    error ReaderRequired();
    error InitialPriceMismatch();
    event PriceReaderUpdated(PoolId indexed poolId, address indexed reader);
    event ReferencePriceUpdated(PoolId indexed poolId, uint160 previousPrice, uint160 referencePrice);

    constructor(IPoolManager manager) StablePairHook(manager) {}

    /// @notice Atomically bind the reader and initialize at its current price.
    /// @dev The caller-supplied referenceSqrtPriceX96 field is ignored; k, optimalFee and targetMultiplier are used.
    function initializeOraclePool(PoolKey calldata key, StableFeeConfig memory config, SqrtPriceReader reader)
        public
        onlyRole(POOL_INITIALIZER_ROLE)
        returns (int24)
    {
        // Do not let an initializer replace the reader of an existing pool.
        if (address(priceReader(key.toId())) != address(0)) revert InvalidPriceReader();
        _setReader(key, reader);
        config.referenceSqrtPriceX96 = reader.read().sqrtPriceX96;
        return initializePool(key, config.referenceSqrtPriceX96, config);
    }

    /// @dev Direct initialization without a reader is disabled for this variant.
    function initializePool(PoolKey calldata key, uint160 sqrtPriceX96, StableFeeConfig memory config)
        public
        override
        onlyRole(POOL_INITIALIZER_ROLE)
        returns (int24)
    {
        SqrtPriceReader reader = priceReader(key.toId());
        if (address(reader) == address(0)) revert ReaderRequired();
        uint160 referencePrice = reader.read().sqrtPriceX96;
        if (sqrtPriceX96 != referencePrice || config.referenceSqrtPriceX96 != referencePrice) {
            revert InitialPriceMismatch();
        }
        return super.initializePool(key, sqrtPriceX96, config);
    }

    /// @notice Replace a pool's trusted reader, validating its pair and live price before accepting it.
    function setPriceReader(PoolKey calldata key, SqrtPriceReader reader) external onlyRole(CONFIG_MANAGER_ROLE) {
        PoolId id = key.toId();
        _checkPoolInitialized(id);
        _setReader(key, reader);
        uint160 referencePrice = reader.read().sqrtPriceX96;
        _validateReferenceSqrtPriceX96(referencePrice);
        _persistReference(id, referencePrice);
        _resetFeeState(id);
    }

    function priceReader(PoolId id) public view returns (SqrtPriceReader) {
        return _oracleStorage().readers[id];
    }

    function _setReader(PoolKey calldata key, SqrtPriceReader reader) private {
        if (
            address(reader).code.length == 0 || reader.token0() != Currency.unwrap(key.currency0)
                || reader.token1() != Currency.unwrap(key.currency1)
        ) revert InvalidPriceReader();
        _validateReaderTokens(key);
        _oracleStorage().readers[key.toId()] = reader;
        emit PriceReaderUpdated(key.toId(), address(reader));
    }

    /// @dev Variant-specific token eligibility checks run whenever a reader is bound or replaced.
    function _validateReaderTokens(PoolKey calldata) internal view virtual {}

    function _loadFeeContext(PoolId id) internal view override returns (FeeContext memory context) {
        context = super._loadFeeContext(id);
        SqrtPriceReader reader = priceReader(id);
        if (address(reader) == address(0)) revert ReaderRequired();
        uint160 referencePrice = reader.read().sqrtPriceX96;
        _validateReferenceSqrtPriceX96(referencePrice);
        if (referencePrice != context.config.referenceSqrtPriceX96) {
            context.config.referenceSqrtPriceX96 = referencePrice;
            context.state = StableFeeState({
                decayingFeeE12: uint40(StableFeeCalculation.UNDEFINED_DECAYING_FEE_E12),
                sqrtAmmPriceX96: 0,
                blockNumber: uint40(_getBlockNumberish())
            });
        }
    }

    function _persistReference(PoolId id, uint160 referencePrice) internal override {
        StableFeeConfig storage config = _getStableFeeConfigurationStorage().feeConfig[id];
        if (referencePrice != config.referenceSqrtPriceX96) {
            emit ReferencePriceUpdated(id, config.referenceSqrtPriceX96, referencePrice);
            config.referenceSqrtPriceX96 = referencePrice;
        }
    }

    function _oracleStorage() private pure returns (OracleStorage storage $) {
        assembly ("memory-safe") { $.slot := ORACLE_STORAGE_LOCATION }
    }
}
