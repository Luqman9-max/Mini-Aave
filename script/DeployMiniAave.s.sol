// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {MiniAave} from "../src/MiniAave.sol";
import {MiniUSD} from "../src/MiniUSD.sol";
import {HelperConfig} from "./HelperConfig.s.sol";

/**
 * @title DeployMiniAave
 * @notice Deployment script for the entire Mini Aave protocol
 *
 * DEPLOYMENT ORDER MATTERS:
 * ─────────────────────────────────────────────────────
 * 1. Get price feed address (from HelperConfig)
 * 2. Deploy MiniUSD (owned by deployer initially)
 * 3. Deploy MiniAave (passing price feed + MUSD address)
 * 4. Transfer MiniUSD ownership to MiniAave
 *    → Now ONLY MiniAave can mint/burn MUSD
 *
 * WHY TRANSFER OWNERSHIP?
 *   If the deployer kept ownership of MiniUSD, they could mint
 *   unlimited tokens and steal collateral. By transferring to
 *   MiniAave, only the protocol's code controls minting.
 */
contract DeployMiniAave is Script {
    function run() external returns (MiniAave, HelperConfig) {
        HelperConfig helperConfig = new HelperConfig();
        HelperConfig.NetworkConfig memory config = helperConfig.getConfigByChainId(block.chainid);

        vm.startBroadcast(msg.sender);

        // Step 1: Deploy MiniUSD (deployer is temporary owner)
        MiniUSD miniUsd = new MiniUSD(msg.sender);

        // Step 2: Deploy MiniAave
        MiniAave miniAave = new MiniAave(config.priceFeed, address(miniUsd));

        // Step 3: Transfer MiniUSD ownership to MiniAave contract
        // After this, only MiniAave can call mint() and burnTokens()
        miniUsd.transferOwnership(address(miniAave));

        vm.stopBroadcast();

        return (miniAave, helperConfig);
    }
}
