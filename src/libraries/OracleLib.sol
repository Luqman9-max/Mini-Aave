// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

/**
 * @title OracleLib
 * @author Mini Aave Team (Educational Project)
 * @notice Library for interacting with Chainlink price feeds
 *
 * ╔══════════════════════════════════════════════════════════════════╗
 * ║                    WHY DO WE NEED THIS FILE?                    ║
 * ╠══════════════════════════════════════════════════════════════════╣
 * ║ This library wraps all Chainlink oracle interactions so that    ║
 * ║ the main MiniAave contract doesn't need to worry about:         ║
 * ║   - Decimal conversion (Chainlink uses 8 decimals, we use 18) ║
 * ║   - Stale price detection (what if the oracle stops updating?) ║
 * ║   - ETH ↔ USD conversion math                                  ║
 * ║                                                                 ║
 * ║ SEPARATION OF CONCERNS: Keep oracle logic separate from         ║
 * ║ lending logic. If Chainlink changes their API, we only          ║
 * ║ update this one file.                                           ║
 * ╚══════════════════════════════════════════════════════════════════╝
 *
 * SOLIDITY CONCEPT: Libraries
 * ─────────────────────────────────────────────────────
 * A library is a collection of reusable functions that can be
 * attached to a type using `using OracleLib for AggregatorV3Interface`.
 *
 * After that, you can call: priceFeed.getLatestPrice()
 * Instead of: OracleLib.getLatestPrice(priceFeed)
 *
 * Libraries cannot hold state (no storage variables).
 * They're perfect for utility/helper functions.
 */
library OracleLib {
    /*//////////////////////////////////////////////////////////////
                             CUSTOM ERRORS
    //////////////////////////////////////////////////////////////*/

    /// @notice Thrown when the price feed hasn't been updated recently enough
    /// @dev This protects against using stale/outdated prices
    error OracleLib__StalePrice();

    /*//////////////////////////////////////////////////////////////
                              CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /**
     * SOLIDITY CONCEPT: constant vs immutable
     * ─────────────────────────────────────────────────────
     * `constant` → value is set at COMPILE time, baked into bytecode
     * `immutable` → value is set at DEPLOY time (in constructor)
     *
     * Both save gas compared to regular storage variables because
     * they don't use a storage slot (SLOAD costs 2100 gas!).
     *
     * Use `constant` when you know the value before deploying.
     * Use `immutable` when the value depends on constructor args.
     */

    /// @notice Maximum allowed time since the last price update (3 hours)
    /// @dev If the price feed hasn't updated in 3 hours, something is wrong
    uint256 private constant TIMEOUT = 3 hours;

    /// @notice The number of additional decimals to add to Chainlink's 8-decimal price
    /// @dev Chainlink ETH/USD returns 8 decimals, we want 18 → add 10
    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;

    /// @notice Standard precision for all our math (18 decimals)
    /// @dev 1e18 = 1.000000000000000000 — like how 1 ETH = 1e18 wei
    uint256 private constant PRECISION = 1e18;

    /*//////////////////////////////////////////////////////////////
                           LIBRARY FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Get the latest ETH/USD price from Chainlink, scaled to 18 decimals
     * @param priceFeed The Chainlink AggregatorV3Interface to query
     * @return price The ETH/USD price with 18 decimal places
     *
     * HOW IT WORKS:
     * 1. Call Chainlink's latestRoundData() to get the current price
     * 2. Check that the price isn't stale (too old)
     * 3. Scale from 8 decimals to 18 decimals
     *
     * EXAMPLE:
     *   Chainlink returns: 200000000000 (= $2000.00000000, 8 decimals)
     *   We multiply by 1e10: 2000000000000000000000 (= $2000.000000000000000000, 18 decimals)
     */
    function getLatestPrice(AggregatorV3Interface priceFeed) internal view returns (uint256 price) {
        // latestRoundData() returns 5 values, but we only need `answer` and `updatedAt`
        // The underscores (_) are placeholders for values we don't use
        (, int256 answer,, uint256 updatedAt,) = priceFeed.latestRoundData();

        // STALENESS CHECK: Make sure the price was updated recently
        // If the oracle stopped responding, we don't want to use outdated prices
        // block.timestamp = current time, updatedAt = last update time
        uint256 secondsSinceUpdate = block.timestamp - updatedAt;
        if (secondsSinceUpdate > TIMEOUT) {
            revert OracleLib__StalePrice();
        }

        // Scale from 8 decimals → 18 decimals
        // We cast int256 → uint256 (safe because price should always be positive)
        return uint256(answer) * ADDITIONAL_FEED_PRECISION;
    }

    /**
     * @notice Convert an ETH amount (in wei) to its USD value (18 decimals)
     * @param priceFeed The Chainlink price feed to use
     * @param ethAmount The amount of ETH in wei (1 ETH = 1e18 wei)
     * @return usdValue The USD value with 18 decimal places
     *
     * EXAMPLE:
     *   ethAmount = 1e18 (1 ETH)
     *   price = 2000e18 ($2000 with 18 decimals)
     *   usdValue = (1e18 * 2000e18) / 1e18 = 2000e18 ($2000)
     *
     * WHY DIVIDE BY PRECISION?
     *   ethAmount has 18 decimals, price has 18 decimals
     *   Multiplying gives 36 decimals — we divide by 1e18 to get back to 18
     */
    function getUsdValue(
        AggregatorV3Interface priceFeed,
        uint256 ethAmount
    ) internal view returns (uint256 usdValue) {
        uint256 ethPrice = getLatestPrice(priceFeed);
        // (ethAmount * ethPrice) / PRECISION
        // e.g., (1e18 * 2000e18) / 1e18 = 2000e18
        return (ethAmount * ethPrice) / PRECISION;
    }

    /**
     * @notice Convert a USD amount (18 decimals) to ETH amount (in wei)
     * @param priceFeed The Chainlink price feed to use
     * @param usdAmount The USD amount with 18 decimal places
     * @return ethAmount The equivalent ETH amount in wei
     *
     * EXAMPLE:
     *   usdAmount = 750e18 ($750)
     *   price = 2000e18 ($2000 per ETH)
     *   ethAmount = (750e18 * 1e18) / 2000e18 = 0.375e18 (0.375 ETH)
     *
     * This is the REVERSE of getUsdValue — we divide by price instead of multiply
     */
    function getEthAmountFromUsd(
        AggregatorV3Interface priceFeed,
        uint256 usdAmount
    ) internal view returns (uint256 ethAmount) {
        uint256 ethPrice = getLatestPrice(priceFeed);
        // (usdAmount * PRECISION) / ethPrice
        // e.g., (750e18 * 1e18) / 2000e18 = 375000000000000000 (0.375 ETH)
        return (usdAmount * PRECISION) / ethPrice;
    }
}
