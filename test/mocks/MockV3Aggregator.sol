// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title MockV3Aggregator
 * @notice A mock Chainlink price feed for local testing
 *
 * WHY DO WE NEED THIS?
 * ─────────────────────────────────────────────────────
 * Chainlink price feeds only exist on real networks (mainnet, Sepolia, etc.).
 * When testing locally on Anvil, there's no Chainlink. So we create a "fake"
 * price feed that behaves the same way but lets us control the price.
 *
 * This is essential for testing liquidation scenarios where we need
 * to simulate price drops (e.g., ETH going from $2000 to $1000).
 */
contract MockV3Aggregator {
    uint8 private s_decimals;
    int256 private s_answer;
    uint256 private s_updatedAt;
    uint80 private s_roundId;

    /// @param _decimals Number of decimals (8 for ETH/USD)
    /// @param _initialAnswer Starting price (e.g., 2000e8 = $2000)
    constructor(uint8 _decimals, int256 _initialAnswer) {
        s_decimals = _decimals;
        s_answer = _initialAnswer;
        s_updatedAt = block.timestamp;
        s_roundId = 1;
    }

    /// @notice Update the mock price — used in tests to simulate price changes
    /// @param _answer The new price (in 8-decimal format)
    function updateAnswer(int256 _answer) external {
        s_answer = _answer;
        s_updatedAt = block.timestamp;
        s_roundId++;
    }

    /// @notice Mimics Chainlink's latestRoundData()
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        return (s_roundId, s_answer, s_updatedAt, s_updatedAt, s_roundId);
    }

    function decimals() external view returns (uint8) {
        return s_decimals;
    }
}
