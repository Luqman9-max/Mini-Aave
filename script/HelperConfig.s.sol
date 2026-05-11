// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";
import {MockV3Aggregator} from "../test/mocks/MockV3Aggregator.sol";

/**
 * @title HelperConfig
 * @notice Provides network-specific configuration for deployments
 *
 * WHY DO WE NEED THIS?
 * ─────────────────────────────────────────────────────
 * Different networks have different Chainlink price feed addresses.
 * On Anvil (local), there IS no Chainlink — we deploy a mock.
 * On Sepolia, we use the real testnet price feed.
 *
 * This pattern lets us deploy the SAME contract code everywhere
 * by swapping out just the configuration.
 */

/// @notice Shared constants across configs
abstract contract CodeConstants {
    uint8 public constant DECIMALS = 8;
    int256 public constant INITIAL_PRICE = 2000e8; // $2000 per ETH

    uint256 public constant ETH_SEPOLIA_CHAIN_ID = 11155111;
    uint256 public constant LOCAL_CHAIN_ID = 31337;
}

contract HelperConfig is CodeConstants, Script {
    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/
    error HelperConfig__InvalidChainId();

    /*//////////////////////////////////////////////////////////////
                                TYPES
    //////////////////////////////////////////////////////////////*/
    struct NetworkConfig {
        address priceFeed;
    }

    /*//////////////////////////////////////////////////////////////
                          STATE VARIABLES
    //////////////////////////////////////////////////////////////*/
    NetworkConfig public localNetworkConfig;
    mapping(uint256 chainId => NetworkConfig) public networkConfigs;

    /*//////////////////////////////////////////////////////////////
                              FUNCTIONS
    //////////////////////////////////////////////////////////////*/
    constructor() {
        networkConfigs[ETH_SEPOLIA_CHAIN_ID] = getSepoliaEthConfig();
    }

    function getConfigByChainId(uint256 chainId) public returns (NetworkConfig memory) {
        if (networkConfigs[chainId].priceFeed != address(0)) {
            return networkConfigs[chainId];
        } else if (chainId == LOCAL_CHAIN_ID) {
            return getOrCreateAnvilEthConfig();
        } else {
            revert HelperConfig__InvalidChainId();
        }
    }

    function getSepoliaEthConfig() public pure returns (NetworkConfig memory) {
        return NetworkConfig({
            priceFeed: 0x694AA1769357215DE4FAC081bf1f309aDC325306 // ETH/USD on Sepolia
        });
    }

    function getOrCreateAnvilEthConfig() public returns (NetworkConfig memory) {
        if (localNetworkConfig.priceFeed != address(0)) {
            return localNetworkConfig;
        }

        console2.log(unicode"⚠️ Deploying mock price feed on Anvil!");
        vm.startBroadcast();
        MockV3Aggregator mockPriceFeed = new MockV3Aggregator(DECIMALS, INITIAL_PRICE);
        vm.stopBroadcast();

        localNetworkConfig = NetworkConfig({priceFeed: address(mockPriceFeed)});
        return localNetworkConfig;
    }
}
