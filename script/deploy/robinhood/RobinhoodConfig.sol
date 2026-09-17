// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ProtocolFeeOracleStablePairHook} from "../../../src/stable/ProtocolFeeOracleStablePairHook.sol";
import {Script} from "forge-std/Script.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IAggregatorV3} from "../../../src/stable/oracles/interfaces/IAggregatorV3.sol";
import {ChainlinkPriceAdapter} from "../../../src/stable/oracles/adapters/ChainlinkPriceAdapter.sol";

interface IFeedDescription {
    function description() external view returns (string memory);
}

/// @notice Versioned token/feed catalog plus explicit operator-selected fee and freshness policy.
abstract contract RobinhoodConfig is Script {
    address internal constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    address public constant MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address public constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address public constant USDG_FEED = 0x61B7e5650328764B076A108EFF5fa7282a1B9aD2;
    uint256 internal constant MIN_TOKEN_DECIMALS = 6;

    struct Policy {
        ProtocolFeeOracleStablePairHook.ProtocolFeeConfig treasury;
        uint24 k;
        uint24 optimalFeeE6;
        uint8 targetMultiplier;
        int24 tickSpacing;
        uint32 stockMaxAge;
        uint32 quoteMaxAge;
        uint32 maxTimestampSkew;
        IAggregatorV3 sequencer;
        uint32 gracePeriod;
    }

    struct Market {
        string symbol;
        address stock;
        address feed;
        uint8 stockDecimals;
        uint8 feedDecimals;
        string description;
    }

    function _policy() internal view returns (Policy memory p) {
        uint256 share = vm.envUint("PROTOCOL_FEE_SHARE_BPS");
        uint256 cap = vm.envUint("MAX_PROTOCOL_FEE_PIPS");
        address recipient = vm.envAddress("PROTOCOL_FEE_RECIPIENT");
        require(share <= 10_000 && cap < 1_000_000, "Invalid treasury policy");
        require(
            share == 0 || cap == 0 || (recipient != address(0) && recipient != MANAGER), "Treasury recipient required"
        );
        p.treasury = ProtocolFeeOracleStablePairHook.ProtocolFeeConfig(recipient, uint16(share), uint24(cap));
        uint256 k = vm.envUint("FEE_K");
        uint256 fee = vm.envUint("OPTIMAL_FEE_E6");
        uint256 target = vm.envUint("TARGET_MULTIPLIER");
        uint256 spacing = vm.envUint("TICK_SPACING");
        require(k > 0 && k <= type(uint24).max && fee <= 10000 && target <= 100, "Invalid fee policy");
        require(spacing > 0 && spacing <= 32767, "Invalid tick spacing");
        p.k = uint24(k);
        p.optimalFeeE6 = uint24(fee);
        p.targetMultiplier = uint8(target);
        p.tickSpacing = int24(int256(spacing));
        p.stockMaxAge = _uint32(vm.envUint("MAX_STOCK_PRICE_AGE"));
        p.quoteMaxAge = _uint32(vm.envUint("MAX_USDG_PRICE_AGE"));
        p.maxTimestampSkew = _uint32(vm.envUint("MAX_TIMESTAMP_SKEW"));
        require(p.stockMaxAge > 0 && p.quoteMaxAge > 0, "Price age required");
        p.sequencer = IAggregatorV3(vm.envOr("SEQUENCER_UPTIME_FEED", address(0)));
        p.gracePeriod = _uint32(vm.envOr("SEQUENCER_GRACE_PERIOD", uint256(0)));
        require((address(p.sequencer) == address(0)) == (p.gracePeriod == 0), "Sequencer policy mismatch");
    }

    function _uint32(uint256 value) private pure returns (uint32) {
        require(value <= type(uint32).max, "Policy overflow");
        return uint32(value);
    }

    function _catalog() internal view returns (string memory json, Market[] memory markets) {
        require(block.chainid == 4663, "Robinhood mainnet only");
        require(MANAGER.code.length > 0 && CREATE2_DEPLOYER.code.length > 0, "Missing chain contracts");
        json = vm.readFile(vm.envOr("MARKETS_FILE", string("script/deploy/robinhood/markets.json")));
        require(vm.parseJsonUint(json, ".chainId") == block.chainid, "Catalog chain mismatch");
        require(vm.parseJsonAddress(json, ".poolManager") == MANAGER, "Manager mismatch");
        require(vm.parseJsonAddress(json, ".quoteToken") == USDG, "Quote token mismatch");
        require(vm.parseJsonAddress(json, ".quoteFeed") == USDG_FEED, "Quote feed mismatch");
        uint256 quoteDecimals = vm.parseJsonUint(json, ".quoteDecimals");
        require(quoteDecimals >= MIN_TOKEN_DECIMALS && quoteDecimals <= 38, "Invalid quote decimals");
        require(IERC20Metadata(USDG).decimals() == quoteDecimals, "USDG decimals changed");
        _checkFeed(
            USDG_FEED, vm.parseJsonUint(json, ".quoteFeedDecimals"), vm.parseJsonString(json, ".quoteDescription")
        );
        uint256 count = vm.parseJsonUint(json, ".marketCount");
        require(count > 0 && count <= 256, "Invalid market count");
        markets = new Market[](count);
        for (uint256 i; i < count; ++i) {
            string memory root = string.concat(".markets[", vm.toString(i), "]");
            Market memory m;
            m.symbol = vm.parseJsonString(json, string.concat(root, ".symbol"));
            m.stock = vm.parseJsonAddress(json, string.concat(root, ".stockToken"));
            m.feed = vm.parseJsonAddress(json, string.concat(root, ".stockFeed"));
            uint256 stockDecimals = vm.parseJsonUint(json, string.concat(root, ".stockDecimals"));
            uint256 feedDecimals = vm.parseJsonUint(json, string.concat(root, ".stockFeedDecimals"));
            require(
                stockDecimals >= MIN_TOKEN_DECIMALS && stockDecimals <= 38 && feedDecimals <= 38, "Invalid decimals"
            );
            m.stockDecimals = uint8(stockDecimals);
            m.feedDecimals = uint8(feedDecimals);
            m.description = vm.parseJsonString(json, string.concat(root, ".stockDescription"));
            require(m.stock != USDG && m.stock.code.length > 0, "Invalid stock token");
            require(IERC20Metadata(m.stock).decimals() == m.stockDecimals, "Stock decimals changed");
            require(
                keccak256(bytes(IERC20Metadata(m.stock).symbol())) == keccak256(bytes(m.symbol)),
                "Token symbol mismatch"
            );
            _checkFeed(m.feed, m.feedDecimals, m.description);
            for (uint256 j; j < i; ++j) {
                require(markets[j].stock != m.stock && markets[j].feed != m.feed, "Duplicate market");
            }
            markets[i] = m;
        }
    }

    function _checkFeed(address feed, uint256 decimals, string memory description) private view {
        require(feed.code.length > 0, "Missing feed");
        require(IAggregatorV3(feed).decimals() == decimals, "Feed decimals changed");
        require(
            keccak256(bytes(IFeedDescription(feed).description())) == keccak256(bytes(description)),
            "Feed description changed"
        );
    }

    function _adapterConfig(Market memory m, Policy memory p)
        internal
        pure
        returns (ChainlinkPriceAdapter.Config memory c)
    {
        bool stock0 = m.stock < USDG;
        c = ChainlinkPriceAdapter.Config({
            feed0: IAggregatorV3(stock0 ? m.feed : USDG_FEED),
            feed1: IAggregatorV3(stock0 ? USDG_FEED : m.feed),
            maxAge0: stock0 ? p.stockMaxAge : p.quoteMaxAge,
            maxAge1: stock0 ? p.quoteMaxAge : p.stockMaxAge,
            maxTimestampSkew: p.maxTimestampSkew,
            sequencerUptimeFeed: p.sequencer,
            sequencerGracePeriod: p.gracePeriod
        });
    }
}
