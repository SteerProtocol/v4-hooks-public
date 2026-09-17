// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {OracleStablePairHook} from "../../src/stable/OracleStablePairHook.sol";
import {StablePairHook} from "../../src/stable/StablePairHook.sol";
import {BaseDynamicFeeHook} from "../../src/base/BaseDynamicFeeHook.sol";
import {StableFeeConfig} from "../../src/stable/interfaces/IStableFeeConfiguration.sol";
import {SqrtPriceReader} from "../../src/stable/oracles/SqrtPriceReader.sol";
import {RobinhoodPriceAdapter, IRobinhoodStockToken} from "../../src/stable/oracles/adapters/RobinhoodPriceAdapter.sol";
import {ChainlinkPriceAdapter} from "../../src/stable/oracles/adapters/ChainlinkPriceAdapter.sol";
import {MockAggregator, MockPriceAdapter} from "./oracles/PriceAdapters.t.sol";
import {IAggregatorV3} from "../../src/stable/oracles/interfaces/IAggregatorV3.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";

contract OracleStablePairHookTest is Test {
    using PoolIdLibrary for PoolKey;
    address constant STOCK = address(0x1000);
    address constant QUOTE = address(0x2000);
    OracleStablePairHook hook;
    SqrtPriceReader reader;
    MockAggregator stockFeed;
    MockAggregator quoteFeed;
    PoolKey key;
    uint160 ammPrice;

    function setUp() public {
        vm.warp(10000);
        vm.roll(100);
        vm.mockCall(STOCK, abi.encodeCall(IERC20Metadata.decimals, ()), abi.encode(uint8(18)));
        vm.mockCall(QUOTE, abi.encodeCall(IERC20Metadata.decimals, ()), abi.encode(uint8(6)));
        _paused(false);
        stockFeed = new MockAggregator(8);
        quoteFeed = new MockAggregator(8);
        _price(200e8);
        quoteFeed.set(1, 1e8, block.timestamp, block.timestamp);
        ChainlinkPriceAdapter.Config memory c =
            ChainlinkPriceAdapter.Config(stockFeed, quoteFeed, 300, 1000, 1000, IAggregatorV3(address(0)), 0);
        reader = new SqrtPriceReader(new RobinhoodPriceAdapter(STOCK, QUOTE, c, true, false));
        OracleStablePairHook impl = new OracleStablePairHook(IPoolManager(address(this)));
        address proxy = address(uint160(0x1000000) | uint160(0x3cc0));
        deployCodeTo(
            "ERC1967Proxy.sol:ERC1967Proxy",
            abi.encode(
                address(impl),
                abi.encodeCall(BaseDynamicFeeHook.initialize, (address(this), address(this), address(this)))
            ),
            proxy
        );
        hook = OracleStablePairHook(proxy);
        key = PoolKey(Currency.wrap(STOCK), Currency.wrap(QUOTE), LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(proxy));
        ammPrice = reader.read().sqrtPriceX96;
        hook.initializeOraclePool(key, StableFeeConfig(16609443, 1000, 50, 0), reader);
    }

    function initialize(PoolKey calldata, uint160 price) external returns (int24) {
        ammPrice = price;
        return 0;
    }

    function extsload(bytes32) external view returns (bytes32) {
        return bytes32(uint256(ammPrice));
    }

    function _price(int256 price) private {
        stockFeed.set(uint80(stockFeed.roundId() + 1), price, block.timestamp, block.timestamp);
    }

    function _paused(bool value) private {
        vm.mockCall(STOCK, abi.encodeCall(IRobinhoodStockToken.oraclePaused, ()), abi.encode(value));
    }

    function _swap(bool zeroForOne) private returns (uint24 fee) {
        (uint24 zero, uint24 one) = hook.getFee(key);
        (,, uint24 actual) = hook.beforeSwap(address(this), key, SwapParams(zeroForOne, -1, 1), "");
        fee = actual & ~LPFeeLibrary.OVERRIDE_FEE_FLAG;
        assertEq(fee, zeroForOne ? zero : one, "preview must match swap");
    }

    function test_initializationUsesReaderAndRejectsStaticPath() public {
        (,,, uint160 referencePrice) = hook.feeConfig(key.toId());
        assertEq(referencePrice, reader.read().sqrtPriceX96);
        PoolKey memory other = key;
        other.tickSpacing = 10;
        vm.expectRevert(OracleStablePairHook.ReaderRequired.selector);
        hook.initializePool(other, ammPrice, StableFeeConfig(16609443, 1000, 50, ammPrice));
    }

    function test_changedReferenceResetsSameBlockAndPreviewDoesNotMutate() public {
        _price(240e8);
        _swap(false);
        vm.roll(110);
        _swap(false);
        (uint40 beforeFee,,) = hook.feeState(key.toId());
        uint160 old = reader.read().sqrtPriceX96;
        _price(160e8); // Crosses the old AMM price, reversing the corrective direction.
        (uint24 sellFee, uint24 buyFee) = hook.getFee(key);
        assertGt(sellFee, 0);
        assertEq(buyFee, 0);
        (,,, uint160 stillStored) = hook.feeConfig(key.toId());
        assertEq(stillStored, old);
        assertEq(_swap(true), sellFee);
        (uint40 afterFee, uint160 cached, uint40 bn) = hook.feeState(key.toId());
        assertTrue(beforeFee != afterFee);
        assertEq(cached, ammPrice);
        assertEq(bn, 110);
        (,,, uint160 updated) = hook.feeConfig(key.toId());
        assertEq(updated, reader.read().sqrtPriceX96);
    }

    function test_identicalPriceNewRoundPreservesAuctionAndCache() public {
        _price(240e8);
        _swap(false);
        vm.roll(110);
        _swap(false);
        (uint40 fee, uint160 cached, uint40 bn) = hook.feeState(key.toId());
        ammPrice = uint160(uint256(ammPrice) * 101 / 100);
        _price(240e8);
        _swap(false);
        (uint40 feeAfter, uint160 cachedAfter, uint40 bnAfter) = hook.feeState(key.toId());
        assertEq(fee, feeAfter);
        assertEq(cached, cachedAfter);
        assertEq(bn, bnAfter);
    }

    function test_pauseBlocksCachedSwapAndPreviewWithRemovalFlagsDisabled() public {
        _swap(true);
        _paused(true);
        vm.expectRevert(abi.encodeWithSelector(RobinhoodPriceAdapter.StockOraclePaused.selector, STOCK));
        hook.getFee(key);
        vm.expectRevert(abi.encodeWithSelector(RobinhoodPriceAdapter.StockOraclePaused.selector, STOCK));
        hook.beforeSwap(address(this), key, SwapParams(true, -1, 1), "");
        Hooks.Permissions memory permissions = hook.getHookPermissions();
        assertFalse(permissions.beforeRemoveLiquidity);
        assertFalse(permissions.afterRemoveLiquidity);
        assertFalse(permissions.beforeSwapReturnDelta);
    }

    function test_staleFeedBlocksCachedSwap() public {
        _swap(true);
        vm.warp(block.timestamp + 301);
        vm.expectRevert(abi.encodeWithSelector(ChainlinkPriceAdapter.InvalidFeed.selector, address(stockFeed)));
        hook.beforeSwap(address(this), key, SwapParams(true, -1, 1), "");
    }

    function test_readerReplacementRequiresRoleAndMatchingPair() public {
        vm.prank(address(999));
        vm.expectRevert();
        hook.setPriceReader(key, reader);
        MockPriceAdapter wrong = new MockPriceAdapter();
        wrong.setTokens(address(0x2000), address(0x3000));
        SqrtPriceReader wrongReader = new SqrtPriceReader(wrong);
        vm.expectRevert(OracleStablePairHook.InvalidPriceReader.selector);
        hook.setPriceReader(key, wrongReader);
        vm.expectRevert(OracleStablePairHook.InvalidPriceReader.selector);
        hook.setPriceReader(key, SqrtPriceReader(address(0)));
        _swap(true);
        hook.setPriceReader(key, reader);
        (, uint160 cache,) = hook.feeState(key.toId());
        assertEq(cache, 0);
    }

    function test_usdgDepegChangesCrossPrice() public {
        uint160 beforePrice = reader.read().sqrtPriceX96;
        quoteFeed.set(2, 5e7, block.timestamp, block.timestamp);
        uint160 afterPrice = reader.read().sqrtPriceX96;
        assertGt(afterPrice, beforePrice);
        _swap(false);
        (,,, uint160 stored) = hook.feeConfig(key.toId());
        assertEq(stored, afterPrice);
    }

    function test_reversePairAndStockStockPause() public {
        ChainlinkPriceAdapter.Config memory c =
            ChainlinkPriceAdapter.Config(quoteFeed, stockFeed, 1000, 300, 1000, IAggregatorV3(address(0)), 0);
        // Treat the higher-address currency as a stock to exercise the second pause flag.
        vm.mockCall(QUOTE, abi.encodeCall(IRobinhoodStockToken.oraclePaused, ()), abi.encode(false));
        RobinhoodPriceAdapter reverse = new RobinhoodPriceAdapter(STOCK, QUOTE, c, false, true);
        assertGt(reverse.readPrice().numerator, 0);
        vm.mockCall(QUOTE, abi.encodeCall(IRobinhoodStockToken.oraclePaused, ()), abi.encode(true));
        vm.expectRevert(abi.encodeWithSelector(RobinhoodPriceAdapter.StockOraclePaused.selector, QUOTE));
        reverse.readPrice();
        vm.mockCall(QUOTE, abi.encodeCall(IRobinhoodStockToken.oraclePaused, ()), abi.encode(false));
        RobinhoodPriceAdapter both = new RobinhoodPriceAdapter(STOCK, QUOTE, c, true, true);
        _paused(true);
        vm.expectRevert(abi.encodeWithSelector(RobinhoodPriceAdapter.StockOraclePaused.selector, STOCK));
        both.readPrice();
    }

    function testFuzz_referenceUpdatesPreserveQuoteSwapParity(uint64 nextPrice, bool zeroForOne) public {
        nextPrice = uint64(bound(nextPrice, 1e8, 10000e8));
        _swap(true);
        vm.roll(block.number + 7);
        _price(int256(uint256(nextPrice)));
        _swap(zeroForOne);
        (,,, uint160 referencePrice) = hook.feeConfig(key.toId());
        assertEq(referencePrice, reader.read().sqrtPriceX96);
    }
}
