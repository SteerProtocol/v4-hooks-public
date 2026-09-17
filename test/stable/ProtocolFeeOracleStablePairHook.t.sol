// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ProtocolFeeClaims} from "../../src/stable/ProtocolFeeClaims.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {ProtocolFeeOracleStablePairHook} from "../../src/stable/ProtocolFeeOracleStablePairHook.sol";
import {OracleStablePairHook} from "../../src/stable/OracleStablePairHook.sol";
import {BaseDynamicFeeHook} from "../../src/base/BaseDynamicFeeHook.sol";
import {StableFeeConfig} from "../../src/stable/interfaces/IStableFeeConfiguration.sol";
import {SqrtPriceReader} from "../../src/stable/oracles/SqrtPriceReader.sol";
import {IPriceAdapter} from "../../src/stable/oracles/interfaces/IPriceAdapter.sol";
import {MockPriceAdapter} from "./oracles/PriceAdapters.t.sol";
import {ProtocolFeeSplit} from "../../src/stable/libraries/ProtocolFeeSplit.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

contract ProtocolFeeOracleStablePairHookTest is Deployers {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    ProtocolFeeOracleStablePairHook hook;
    address constant TREASURY = address(0xFEE);
    MockPriceAdapter adapter;
    SqrtPriceReader reader;
    PoolKey baseline;

    function setUp() public {
        vm.warp(10000);
        vm.roll(100);
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();
        adapter = new MockPriceAdapter();
        adapter.setTokens(Currency.unwrap(currency0), Currency.unwrap(currency1));
        adapter.set(IPriceAdapter.Price(1, 1, 0, 0, 0));
        reader = new SqrtPriceReader(adapter);
        ProtocolFeeOracleStablePairHook impl = new ProtocolFeeOracleStablePairHook(manager);
        address proxy = address(uint160(0x1000000 | 0x3ccc));
        deployCodeTo(
            "ERC1967Proxy.sol:ERC1967Proxy",
            abi.encode(
                address(impl),
                abi.encodeCall(BaseDynamicFeeHook.initialize, (address(this), address(this), address(this)))
            ),
            proxy
        );
        hook = ProtocolFeeOracleStablePairHook(proxy);
        key = PoolKey(currency0, currency1, 0x800000, 60, IHooks(proxy));
        hook.initializeOraclePoolWithProtocolFee(
            key,
            StableFeeConfig(16609443, 10000, 50, 0),
            reader,
            ProtocolFeeOracleStablePairHook.ProtocolFeeConfig(TREASURY, 1000, 1000)
        );
        // Identical oracle pool without fee sharing is the execution comparator.
        OracleStablePairHook plain = new OracleStablePairHook(manager);
        address plainProxy = address(uint160(0x2000000 | 0x3cc0));
        deployCodeTo(
            "ERC1967Proxy.sol:ERC1967Proxy",
            abi.encode(
                address(plain),
                abi.encodeCall(BaseDynamicFeeHook.initialize, (address(this), address(this), address(this)))
            ),
            plainProxy
        );
        baseline = PoolKey(currency0, currency1, 0x800000, 60, IHooks(plainProxy));
        OracleStablePairHook(plainProxy).initializeOraclePool(baseline, StableFeeConfig(16609443, 10000, 50, 0), reader);
        _liquidity(key);
        _liquidity(baseline);
    }

    function _liquidity(PoolKey memory k) private {
        modifyLiquidityRouter.modifyLiquidity(k, ModifyLiquidityParams(-600, 600, 1e24, 0), "");
        // Extra ranges force multiple fee-rounding steps in the large-trade test.
        modifyLiquidityRouter.modifyLiquidity(k, ModifyLiquidityParams(-120, 120, 1e24, 0), "");
    }

    function _swap(PoolKey memory k, bool direction, int256 amount, uint160 limit) private returns (BalanceDelta) {
        return swapRouter.swap(k, SwapParams(direction, amount, limit), PoolSwapTest.TestSettings(false, false), "");
    }

    function _limit(bool direction) private pure returns (uint160) {
        return direction ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
    }

    function _mockReader(address token0, address token1) private returns (PoolKey memory other, SqrtPriceReader r) {
        MockPriceAdapter mockAdapter = new MockPriceAdapter();
        mockAdapter.setTokens(token0, token1);
        mockAdapter.set(IPriceAdapter.Price(1, 1, 0, 0, 0));
        r = new SqrtPriceReader(mockAdapter);
        other = PoolKey(Currency.wrap(token0), Currency.wrap(token1), 0x800000, 10, IHooks(address(hook)));
    }

    function _compare(bool direction, bool exactInput, uint256 amount) private {
        int256 specified = exactInput ? -int256(amount) : int256(amount);
        BalanceDelta original = _swap(baseline, direction, specified, _limit(direction));
        BalanceDelta split = _swap(key, direction, specified, _limit(direction));
        int128 originalIn = direction ? original.amount0() : original.amount1();
        int128 splitIn = direction ? split.amount0() : split.amount1();
        int128 originalOut = direction ? original.amount1() : original.amount0();
        int128 splitOut = direction ? split.amount1() : split.amount0();
        if (exactInput) {
            assertEq(splitIn, originalIn);
            assertApproxEqAbs(uint128(splitOut), uint128(originalOut), 8, "net output rounding");
        } else {
            assertEq(splitOut, originalOut);
            assertApproxEqAbs(uint256(-int256(splitIn)), uint256(-int256(originalIn)), 8, "gross input rounding");
        }
        Currency input = direction ? currency0 : currency1;
        uint256 earned = manager.balanceOf(TREASURY, input.toId());
        assertGt(earned, 0);
        uint256 gross = uint256(-int256(splitIn));
        assertLe(earned * 1_000_000, gross * 1000, "cap");
        assertEq(manager.balanceOf(address(hook), input.toId()), 0);
    }

    function testFuzz_executionMatchesOriginal(bool direction, bool exactInput, uint96 amount) public {
        _compare(direction, exactInput, bound(amount, 1e9, 1e21));
    }

    function test_crossTicksBothDirectionsAndSwapTypes() public {
        for (uint256 i; i < 4; ++i) {
            uint256 snap = vm.snapshotState();
            _compare(i & 1 != 0, i & 2 != 0, 2e22);
            vm.revertToState(snap);
        }
    }

    function test_nativeProtocolFeesBothDirectionsAndSwapTypes() public {
        vm.startPrank(feeController);
        manager.setProtocolFee(key, 500 | (1000 << 12));
        manager.setProtocolFee(baseline, 500 | (1000 << 12));
        vm.stopPrank();
        for (uint256 i; i < 4; ++i) {
            uint256 snap = vm.snapshotState();
            _compare(i & 1 != 0, i & 2 != 0, 1e20);
            vm.revertToState(snap);
        }
    }

    function test_partialExactInputRevertsAndAccruesNothing() public {
        for (uint256 i; i < 2; ++i) {
            bool direction = i == 0;
            vm.expectRevert(); // PoolManager wraps the hook's PartialExactInput error.
            _swap(key, direction, -int256(1e22), TickMath.getSqrtPriceAtTick(direction ? int24(-1) : int24(1)));
            assertEq(manager.balanceOf(TREASURY, (direction ? currency0 : currency1).toId()), 0);
        }
    }

    function test_partialExactOutputChargesActualInput() public {
        ProtocolFeeSplit.Quote memory q = hook.getFeeSplit(key, true);
        BalanceDelta delta = _swap(key, true, 1e22, TickMath.getSqrtPriceAtTick(-1));
        assertLt(uint128(delta.amount1()), 1e22);
        uint256 accrued = manager.balanceOf(TREASURY, currency0.toId());
        uint256 total = uint256(-int256(delta.amount0()));
        assertEq(accrued, ProtocolFeeSplit.exactOutput(total - accrued, q));
        assertLt(accrued, 1e22 * 1000 / 1e6);
    }

    function test_tinyExactOutputRevertsWithoutDiscount() public {
        for (uint256 i; i < 2; ++i) {
            uint256 snap = vm.snapshotState();
            bool direction = i == 0;
            try swapRouter.swap(
                key, SwapParams(direction, 202, _limit(direction)), PoolSwapTest.TestSettings(false, false), ""
            ) {
                fail();
            } catch (bytes memory reason) {
                this.decodeMinimumFeeFailure(reason);
            }
            assertEq(manager.balanceOf(TREASURY, (direction ? currency0 : currency1).toId()), 0);
            vm.revertToState(snap);
        }
    }

    function test_tinyExactOutputRevertsWithNativeProtocolFee() public {
        vm.startPrank(feeController);
        manager.setProtocolFee(key, 500 | (1000 << 12));
        vm.stopPrank();
        try swapRouter.swap(key, SwapParams(true, 202, _limit(true)), PoolSwapTest.TestSettings(false, false), "") {
            fail();
        } catch (bytes memory reason) {
            this.decodeMinimumFeeFailure(reason);
        }
        assertEq(manager.balanceOf(TREASURY, currency0.toId()), 0);
    }

    function test_exactOutputAccruesOnceFeeRoundsToOneUnit() public {
        for (uint256 i; i < 2; ++i) {
            uint256 snap = vm.snapshotState();
            bool direction = i == 0;
            BalanceDelta delta = _swap(key, direction, 1000, _limit(direction));
            assertEq(uint128(direction ? delta.amount1() : delta.amount0()), 1000);
            assertGt(manager.balanceOf(TREASURY, (direction ? currency0 : currency1).toId()), 0);
            vm.revertToState(snap);
        }
    }

    function test_zeroSharePreservesPartialFills() public {
        hook.setProtocolFeeConfig(key.toId(), ProtocolFeeOracleStablePairHook.ProtocolFeeConfig(address(0), 0, 1000));
        BalanceDelta delta = _swap(key, true, -int256(1e22), TickMath.getSqrtPriceAtTick(-1));
        assertLt(uint256(-int256(delta.amount0())), 1e22);
        assertEq(manager.balanceOf(TREASURY, currency0.toId()), 0);
    }

    function test_zeroSharePreservesTinyExactOutput() public {
        hook.setProtocolFeeConfig(key.toId(), ProtocolFeeOracleStablePairHook.ProtocolFeeConfig(address(0), 0, 1000));
        BalanceDelta delta = _swap(key, true, 202, _limit(true));
        assertEq(uint128(delta.amount1()), 202);
        assertEq(manager.balanceOf(TREASURY, currency0.toId()), 0);
    }

    function test_zeroAuctionFeeDoesNotChargeTreasury() public {
        adapter.set(IPriceAdapter.Price(2, 1, 0, 0, 0)); // Price below reference; zeroForOne is the zero-fee direction.
        (uint24 fee,) = hook.getFee(key);
        assertEq(fee, 0);
        BalanceDelta delta = _swap(key, true, 202, _limit(true));
        assertEq(uint128(delta.amount1()), 202);
        assertEq(manager.balanceOf(TREASURY, currency0.toId()), 0);
    }

    function testFuzz_initializeRejectsEitherTokenBelowSixDecimals(uint8 decimals, bool firstToken) public {
        decimals = uint8(bound(decimals, 0, 5));
        PoolKey memory other = key;
        other.tickSpacing = 10;
        vm.mockCall(
            Currency.unwrap(firstToken ? currency0 : currency1),
            abi.encodeCall(IERC20Metadata.decimals, ()),
            abi.encode(decimals)
        );
        vm.mockCall(
            Currency.unwrap(firstToken ? currency1 : currency0),
            abi.encodeCall(IERC20Metadata.decimals, ()),
            abi.encode(uint8(6))
        );
        vm.expectRevert(ProtocolFeeOracleStablePairHook.UnsupportedTokenDecimals.selector);
        hook.initializeOraclePool(other, StableFeeConfig(16609443, 10000, 50, 0), reader);
        assertEq(address(hook.priceReader(other.toId())), address(0));
        vm.clearMockedCalls();
    }

    function test_sixDecimalTokensCanInitializeAndEnableCollection() public {
        PoolKey memory other = key;
        other.tickSpacing = 10;
        vm.mockCall(Currency.unwrap(currency0), abi.encodeCall(IERC20Metadata.decimals, ()), abi.encode(uint8(6)));
        vm.mockCall(Currency.unwrap(currency1), abi.encodeCall(IERC20Metadata.decimals, ()), abi.encode(uint8(6)));
        hook.initializeOraclePool(other, StableFeeConfig(16609443, 10000, 50, 0), reader);
        assertEq(address(hook.priceReader(other.toId())), address(reader));
        hook.setProtocolFeeConfig(other.toId(), ProtocolFeeOracleStablePairHook.ProtocolFeeConfig(TREASURY, 1000, 1000));
        assertEq(hook.protocolFeeConfig(other.toId()).protocolFeeShareBps, 1000);
        vm.clearMockedCalls();
    }

    function test_readerReplacementRechecksTokenDecimals() public {
        SqrtPriceReader replacement = new SqrtPriceReader(adapter);
        vm.mockCall(Currency.unwrap(currency0), abi.encodeCall(IERC20Metadata.decimals, ()), abi.encode(uint8(5)));
        vm.expectRevert(ProtocolFeeOracleStablePairHook.UnsupportedTokenDecimals.selector);
        hook.setPriceReader(key, replacement);
        assertEq(address(hook.priceReader(key.toId())), address(reader));
        vm.clearMockedCalls();
    }

    function test_initializeRejectsMissingTokenDecimals() public {
        address token0 = address(0x1111);
        address token1 = address(0x2222);
        (PoolKey memory other, SqrtPriceReader otherReader) = _mockReader(token0, token1);
        vm.mockCall(token1, abi.encodeCall(IERC20Metadata.decimals, ()), abi.encode(uint8(6)));
        vm.expectRevert(ProtocolFeeOracleStablePairHook.UnsupportedTokenDecimals.selector);
        hook.initializeOraclePool(other, StableFeeConfig(16609443, 10000, 50, 0), otherReader);
        assertEq(address(hook.priceReader(other.toId())), address(0));
        vm.clearMockedCalls();
    }

    function test_initializeRejectsMalformedTokenDecimals() public {
        address token0 = address(0x1111);
        address token1 = address(0x2222);
        (PoolKey memory other, SqrtPriceReader otherReader) = _mockReader(token0, token1);
        vm.mockCall(token0, abi.encodeCall(IERC20Metadata.decimals, ()), abi.encode(uint256(256)));
        vm.mockCall(token1, abi.encodeCall(IERC20Metadata.decimals, ()), abi.encode(uint8(6)));
        vm.expectRevert(ProtocolFeeOracleStablePairHook.UnsupportedTokenDecimals.selector);
        hook.initializeOraclePool(other, StableFeeConfig(16609443, 10000, 50, 0), otherReader);
        assertEq(address(hook.priceReader(other.toId())), address(0));
        vm.clearMockedCalls();
    }

    function _stateHash() private view returns (bytes32) {
        (uint40 fee, uint160 price, uint40 number) = hook.feeState(key.toId());
        return keccak256(abi.encode(fee, price, number));
    }

    function test_configSeparateAccessControlledAndDoesNotResetAuction() public {
        _swap(key, true, -int256(1e18), _limit(true));
        bytes32 beforeState = _stateHash();
        vm.prank(address(999));
        vm.expectRevert();
        hook.setProtocolFeeConfig(key.toId(), ProtocolFeeOracleStablePairHook.ProtocolFeeConfig(TREASURY, 2000, 50));
        hook.setProtocolFeeConfig(key.toId(), ProtocolFeeOracleStablePairHook.ProtocolFeeConfig(TREASURY, 2000, 50));
        assertEq(beforeState, _stateHash());
        (, uint24 optimal,,) = hook.feeConfig(key.toId());
        assertEq(optimal, 10000);
        vm.expectRevert(ProtocolFeeOracleStablePairHook.InvalidProtocolFeeConfig.selector);
        hook.setProtocolFeeConfig(key.toId(), ProtocolFeeOracleStablePairHook.ProtocolFeeConfig(TREASURY, 10001, 50));
        vm.expectRevert(ProtocolFeeOracleStablePairHook.InvalidProtocolFeeConfig.selector);
        hook.setProtocolFeeConfig(key.toId(), ProtocolFeeOracleStablePairHook.ProtocolFeeConfig(address(0), 1000, 50));
    }

    function test_claimsRedeemableByRecipient() public {
        _swap(key, true, -int256(1e18), _limit(true));
        uint256 earned = manager.balanceOf(TREASURY, currency0.toId());
        ProtocolFeeClaims claims = new ProtocolFeeClaims(manager);
        Currency[] memory currencies = new Currency[](3);
        currencies[0] = currency0;
        currencies[1] = currency1;
        currencies[2] = currency0; // Duplicate and zero balances are harmless.
        vm.prank(TREASURY);
        manager.setOperator(address(claims), true);
        claims.withdraw(currencies); // An unrelated caller cannot redeem the treasury's balance.
        assertEq(manager.balanceOf(TREASURY, currency0.toId()), earned);
        vm.prank(TREASURY);
        claims.withdraw(currencies);
        assertEq(manager.balanceOf(TREASURY, currency0.toId()), 0);
        assertEq(currency0.balanceOf(TREASURY), earned);
    }

    function test_runtimeFitsEip170() public {
        ProtocolFeeOracleStablePairHook impl = new ProtocolFeeOracleStablePairHook(manager);
        assertLe(address(impl).code.length, 24576, "Use the robinhood compiler profile");
    }

    function decodeLimitFailure(bytes calldata reason) external view returns (uint256 executable) {
        assertEq(bytes4(reason[:4]), CustomRevert.WrappedError.selector);
        (address target, bytes4 callback, bytes memory inner,) = abi.decode(reason[4:], (address, bytes4, bytes, bytes));
        assertEq(target, address(hook));
        assertEq(callback, IHooks.afterSwap.selector);
        return this.decodePartial(inner);
    }

    function decodePartial(bytes calldata reason) external pure returns (uint256 executable) {
        assertEq(bytes4(reason[:4]), ProtocolFeeOracleStablePairHook.PartialExactInput.selector);
        (, executable) = abi.decode(reason[4:], (uint256, uint256));
    }

    function decodeMinimumFeeFailure(bytes calldata reason) external view {
        assertEq(bytes4(reason[:4]), CustomRevert.WrappedError.selector);
        (address target, bytes4 callback, bytes memory inner,) = abi.decode(reason[4:], (address, bytes4, bytes, bytes));
        assertEq(target, address(hook));
        assertEq(callback, IHooks.afterSwap.selector);
        this.decodeMinimumFee(inner);
    }

    function decodeMinimumFee(bytes calldata reason) external pure {
        assertEq(reason.length, 4);
        assertEq(bytes4(reason[:4]), ProtocolFeeOracleStablePairHook.ProtocolFeeBelowMinimum.selector);
    }

    function test_quoteCanReduceInputAndRetryAtSameLimit() public {
        uint160 limit = TickMath.getSqrtPriceAtTick(-1);
        uint256 executable;
        try swapRouter.swap(key, SwapParams(true, -int256(1e22), limit), PoolSwapTest.TestSettings(false, false), "") {
            fail();
        } catch (bytes memory reason) {
            executable = this.decodeLimitFailure(reason);
        }
        assertGt(executable, 0);
        assertLt(executable, 1e22);
        BalanceDelta delta = _swap(key, true, -int256(executable), limit);
        assertEq(uint256(-int256(delta.amount0())), executable);
    }

    function test_permissionsAndCallbackAuthorization() public {
        Hooks.Permissions memory p = hook.getHookPermissions();
        assertTrue(p.beforeSwapReturnDelta && p.afterSwapReturnDelta);
        assertFalse(p.beforeRemoveLiquidity || p.afterRemoveLiquidity);
        vm.expectRevert();
        hook.beforeSwap(address(this), key, SwapParams(true, -1, _limit(true)), "");
    }
}
