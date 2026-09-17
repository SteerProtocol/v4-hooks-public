// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {DeployRobinhoodMarkets} from "../../script/deploy/robinhood/DeployRobinhoodMarkets.s.sol";
import {OracleStablePairHook} from "../../src/stable/OracleStablePairHook.sol";
import {RobinhoodPriceAdapter} from "../../src/stable/oracles/adapters/RobinhoodPriceAdapter.sol";
import {ChainlinkPriceAdapter} from "../../src/stable/oracles/adapters/ChainlinkPriceAdapter.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";

contract RobinhoodDeploymentTest is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    address constant MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address constant QUOTE_FEED = 0x61B7e5650328764B076A108EFF5fa7282a1B9aD2;
    address constant DEPLOYER = address(0xBEEF);
    DeployRobinhoodMarkets script;
    string catalog;

    function setUp() public {
        vm.chainId(4663);
        vm.warp(10000);
        vm.roll(100);
        vm.etch(address(100), hex"fe"); // Model the real RPC placeholder for the native ArbSys precompile.
        deployCodeTo("PoolManager.sol:PoolManager", abi.encode(address(this)), MANAGER);
        vm.etch(
            0x4e59b44847b379578588920cA78FbF26c0B4956C,
            hex"7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe03601600081602082378035828234f58015156039578182fd5b8082525050506014600cf3"
        );
        string memory path = vm.envOr("TEST_MARKETS_FILE", string("script/deploy/robinhood/markets.json"));
        catalog = vm.readFile(path);
        vm.setEnv("MARKETS_FILE", path);
        vm.setEnv("DEPLOYER", vm.toString(DEPLOYER));
        vm.setEnv("HOOK_ADMIN", vm.toString(address(this)));
        vm.setEnv("CONFIG_MANAGER", vm.toString(address(this)));
        vm.setEnv("FEE_K", "16609443");
        vm.setEnv("OPTIMAL_FEE_E6", "1000");
        vm.setEnv("TARGET_MULTIPLIER", "50");
        vm.setEnv("TICK_SPACING", "60");
        vm.setEnv("MAX_STOCK_PRICE_AGE", "300");
        vm.setEnv("MAX_USDG_PRICE_AGE", "1000");
        vm.setEnv("MAX_TIMESTAMP_SKEW", "1000");
        vm.setEnv("SEQUENCER_UPTIME_FEED", vm.toString(address(0)));
        vm.setEnv("SEQUENCER_GRACE_PERIOD", "0");
        vm.setEnv("MARKET_START", "0");
        vm.setEnv("MARKET_END", "35");
        _mockToken(USDG, "USDG", 6);
        _mockFeed(QUOTE_FEED, "USDG / USD", 1e8);
        for (uint256 i; i < 35; ++i) {
            string memory root = string.concat(".markets[", vm.toString(i), "]");
            _mockToken(
                vm.parseJsonAddress(catalog, string.concat(root, ".stockToken")),
                vm.parseJsonString(catalog, string.concat(root, ".symbol")),
                18
            );
            _mockFeed(
                vm.parseJsonAddress(catalog, string.concat(root, ".stockFeed")),
                vm.parseJsonString(catalog, string.concat(root, ".stockDescription")),
                200e8
            );
        }
        script = new DeployRobinhoodMarkets();
    }

    function _mockToken(address token, string memory symbol, uint8 decimals) private {
        vm.etch(token, hex"00");
        vm.mockCall(token, abi.encodeWithSignature("decimals()"), abi.encode(decimals));
        vm.mockCall(token, abi.encodeWithSignature("symbol()"), abi.encode(symbol));
        vm.mockCall(token, abi.encodeWithSignature("oraclePaused()"), abi.encode(false));
    }

    function _mockFeed(address feed, string memory description, int256 price) private {
        vm.etch(feed, hex"00");
        vm.mockCall(feed, abi.encodeWithSignature("decimals()"), abi.encode(uint8(8)));
        vm.mockCall(feed, abi.encodeWithSignature("description()"), abi.encode(description));
        vm.mockCall(
            feed,
            abi.encodeWithSignature("latestRoundData()"),
            abi.encode(uint80(1), price, block.timestamp, block.timestamp, uint80(1))
        );
    }

    function test_all35MarketsInitializeAndRerunIsIdempotent() public {
        OracleStablePairHook hook = script.run();
        uint64 nonce = vm.getNonce(DEPLOYER);
        OracleStablePairHook again = script.run();
        assertEq(address(again), address(hook));
        assertEq(vm.getNonce(DEPLOYER), nonce, "rerun must not broadcast transactions");
        for (uint256 i; i < 35; ++i) {
            address stock = vm.parseJsonAddress(catalog, string.concat(".markets[", vm.toString(i), "].stockToken"));
            bool stock0 = stock < USDG;
            PoolKey memory key = PoolKey(
                Currency.wrap(stock0 ? stock : USDG),
                Currency.wrap(stock0 ? USDG : stock),
                0x800000,
                60,
                IHooks(address(hook))
            );
            (uint160 price,,,) = IPoolManager(MANAGER).getSlot0(key.toId());
            assertEq(price, hook.priceReader(key.toId()).read().sqrtPriceX96);
            (uint24 zero, uint24 one) = hook.getFee(key);
            assertEq(zero, 1000);
            assertEq(one, 1000);
        }
    }

    function test_wrongChainStopsBeforeDeployment() public {
        vm.chainId(1);
        vm.expectRevert("Robinhood mainnet only");
        script.run();
        assertEq(vm.getNonce(DEPLOYER), 0);
    }

    function test_pausedLastMarketStopsBeforeAnyBroadcast() public {
        address stock = vm.parseJsonAddress(catalog, ".markets[34].stockToken");
        vm.mockCall(stock, abi.encodeWithSignature("oraclePaused()"), abi.encode(true));
        vm.expectRevert(abi.encodeWithSelector(RobinhoodPriceAdapter.StockOraclePaused.selector, stock));
        script.run();
        assertEq(vm.getNonce(DEPLOYER), 0);
    }

    function test_staleLastMarketStopsBeforeAnyBroadcast() public {
        address feed = vm.parseJsonAddress(catalog, ".markets[34].stockFeed");
        vm.mockCall(
            feed,
            abi.encodeWithSignature("latestRoundData()"),
            abi.encode(uint80(1), int256(200e8), uint256(1), uint256(1), uint80(1))
        );
        vm.expectRevert(abi.encodeWithSelector(ChainlinkPriceAdapter.InvalidFeed.selector, feed));
        script.run();
        assertEq(vm.getNonce(DEPLOYER), 0);
    }
}
