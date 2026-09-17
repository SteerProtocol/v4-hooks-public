// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ProtocolFeeClaims} from "../../../src/stable/ProtocolFeeClaims.sol";
import {RobinhoodConfig} from "./RobinhoodConfig.sol";
import {console2} from "forge-std/console2.sol";
import {ProtocolFeeOracleStablePairHook} from "../../../src/stable/ProtocolFeeOracleStablePairHook.sol";
import {BaseDynamicFeeHook} from "../../../src/base/BaseDynamicFeeHook.sol";
import {StableFeeConfig} from "../../../src/stable/interfaces/IStableFeeConfiguration.sol";
import {RobinhoodPriceAdapter} from "../../../src/stable/oracles/adapters/RobinhoodPriceAdapter.sol";
import {SqrtPriceReader} from "../../../src/stable/oracles/SqrtPriceReader.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

/// @notice Deploy one oracle-backed hook and all catalog stock/USDG pools (no liquidity deposits).
/// @dev forge script simulates by default. Broadcasting requires the separate --broadcast option.
///      Reruns reuse CREATE2 addresses and reject changed configuration on already initialized pools.
contract DeployRobinhoodMarkets is RobinhoodConfig {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint160 internal constant FLAGS = Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG
        | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG
        | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;

    address internal broadcaster;

    function run() external returns (ProtocolFeeOracleStablePairHook hook) {
        // Foundry's ordinary EVM sees ArbSys as the RPC's INVALID-byte placeholder, not a
        // native precompile. Model its block-number response in the local simulation only.
        // vm.mockCall is a cheatcode and is never included in broadcast transactions.
        if (block.chainid == 4663 && address(100).codehash == keccak256(hex"fe")) {
            vm.mockCall(address(100), bytes4(0xa3b1b31d), abi.encode(block.number));
        }
        (, Market[] memory markets) = _catalog();
        Policy memory policy = _policy();
        broadcaster = vm.envAddress("DEPLOYER");
        address admin = vm.envAddress("HOOK_ADMIN");
        address configManager = vm.envAddress("CONFIG_MANAGER");
        require(broadcaster != address(0) && admin != address(0) && configManager != address(0), "Roles required");
        uint256 start = vm.envOr("MARKET_START", uint256(0));
        uint256 end = vm.envOr("MARKET_END", markets.length);
        require(start < end && end <= markets.length, "Invalid market interval");

        // Validate every selected live price before collecting any broadcast transactions.
        // These temporary contracts are simulation-only and are not included in broadcasts.
        for (uint256 i = start; i < end; ++i) {
            Market memory m = markets[i];
            bool stock0 = m.stock < USDG;
            RobinhoodPriceAdapter probe = new RobinhoodPriceAdapter(
                stock0 ? m.stock : USDG, stock0 ? USDG : m.stock, _adapterConfig(m, policy), stock0, !stock0
            );
            SqrtPriceReader reader = new SqrtPriceReader(probe);
            console2.log("Preflight", m.symbol, uint256(reader.read().sqrtPriceX96));
        }
        hook = _deployHook(admin, configManager);
        address claims = _deploy(
            abi.encodePacked(type(ProtocolFeeClaims).creationCode, abi.encode(MANAGER)),
            keccak256("Steer.ProtocolFeeClaims.v1"),
            1_000_000
        );
        console2.log("ProtocolFeeClaims", claims);
        for (uint256 i = start; i < end; ++i) {
            _deployMarket(hook, markets[i], policy);
        }
        console2.log("ProtocolFeeOracleStablePairHook", address(hook));
        console2.log("Markets prepared", end - start);
    }

    function _deployHook(address admin, address configManager) private returns (ProtocolFeeOracleStablePairHook hook) {
        bytes memory implementationCode =
            abi.encodePacked(type(ProtocolFeeOracleStablePairHook).creationCode, abi.encode(MANAGER));
        address implementation =
            _deploy(implementationCode, keccak256("Steer.ProtocolFeeOracleStablePairHook.v1"), 7_000_000);
        bytes memory initialize = abi.encodeCall(BaseDynamicFeeHook.initialize, (admin, broadcaster, configManager));
        bytes memory proxyCode =
            abi.encodePacked(type(ERC1967Proxy).creationCode, abi.encode(implementation, initialize));
        bytes32 salt = _mine(keccak256(proxyCode));
        hook = ProtocolFeeOracleStablePairHook(_deploy(proxyCode, salt, 600_000));
        require(
            address(uint160(uint256(vm.load(address(hook), ERC1967Utils.IMPLEMENTATION_SLOT)))) == implementation,
            "Implementation changed"
        );
        require(address(hook.poolManager()) == MANAGER, "Hook manager mismatch");
        require(
            hook.hasRole(hook.DEFAULT_ADMIN_ROLE(), admin) && hook.hasRole(hook.POOL_INITIALIZER_ROLE(), broadcaster)
                && hook.hasRole(hook.CONFIG_MANAGER_ROLE(), configManager),
            "Hook roles changed"
        );
        console2.log("Implementation", implementation);
        console2.log("Proxy salt");
        console2.logBytes32(salt);
    }

    function _deployMarket(ProtocolFeeOracleStablePairHook hook, Market memory m, Policy memory p) private {
        bool stock0 = m.stock < USDG;
        address token0 = stock0 ? m.stock : USDG;
        address token1 = stock0 ? USDG : m.stock;
        bytes32 salt = keccak256(abi.encode("Steer.RobinhoodMarket.v1", token0, token1));
        address adapter = _deploy(
            abi.encodePacked(
                type(RobinhoodPriceAdapter).creationCode,
                abi.encode(token0, token1, _adapterConfig(m, p), stock0, !stock0)
            ),
            salt,
            2_000_000
        );
        SqrtPriceReader reader = SqrtPriceReader(
            _deploy(abi.encodePacked(type(SqrtPriceReader).creationCode, abi.encode(adapter)), salt, 1_000_000)
        );
        PoolKey memory key = PoolKey(
            Currency.wrap(token0),
            Currency.wrap(token1),
            LPFeeLibrary.DYNAMIC_FEE_FLAG,
            p.tickSpacing,
            IHooks(address(hook))
        );
        _initializeMarket(hook, key, p, reader);
        console2.log("Market", m.symbol);
        console2.logBytes32(PoolId.unwrap(key.toId()));
        console2.log("Adapter", adapter);
        console2.log("Reader", address(reader));
    }

    function _initializeMarket(
        ProtocolFeeOracleStablePairHook hook,
        PoolKey memory key,
        Policy memory p,
        SqrtPriceReader reader
    ) private {
        PoolId id = key.toId();
        (uint24 k, uint24 fee, uint8 target, uint160 referencePrice) = hook.feeConfig(id);
        if (referencePrice == 0) {
            StableFeeConfig memory config = StableFeeConfig(p.k, p.optimalFeeE6, p.targetMultiplier, 0);
            vm.broadcast(broadcaster);
            hook.initializeOraclePoolWithProtocolFee{gas: 1_000_000}(key, config, reader, p.treasury);
        } else {
            require(k == p.k && fee == p.optimalFeeE6 && target == p.targetMultiplier, "Existing fee policy mismatch");
            require(address(hook.priceReader(id)) == address(reader), "Existing reader mismatch");
        }
        ProtocolFeeOracleStablePairHook.ProtocolFeeConfig memory actual = hook.protocolFeeConfig(id);
        require(keccak256(abi.encode(actual)) == keccak256(abi.encode(p.treasury)), "Existing treasury policy mismatch");
        (uint160 poolPrice,,,) = IPoolManager(MANAGER).getSlot0(id);
        require(poolPrice != 0 && address(hook.priceReader(id)) == address(reader), "Pool verification failed");
        hook.getFee(key);
    }

    function _deploy(bytes memory initCode, bytes32 salt, uint256 gasLimit) private returns (address expected) {
        expected = _address(keccak256(initCode), salt);
        if (expected.code.length == 0) {
            vm.broadcast(broadcaster);
            (bool success,) = CREATE2_DEPLOYER.call{gas: gasLimit}(abi.encodePacked(salt, initCode));
            require(success && expected.code.length > 0, "CREATE2 deployment failed");
        }
    }

    /// @dev Include occupied addresses so identical reruns resolve to the same proxy.
    function _mine(bytes32 initHash) private pure returns (bytes32) {
        for (uint256 i; i < 160444; ++i) {
            if (uint160(_address(initHash, bytes32(i))) & Hooks.ALL_HOOK_MASK == FLAGS) return bytes32(i);
        }
        revert("No hook salt found");
    }

    function _address(bytes32 initHash, bytes32 salt) private pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), CREATE2_DEPLOYER, salt, initHash)))));
    }
}
