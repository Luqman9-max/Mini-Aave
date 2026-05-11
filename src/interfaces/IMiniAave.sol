// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IMiniAave
 * @author Mini Aave Team (Educational Project)
 * @notice Interface for the MiniAave lending protocol
 *
 * ╔══════════════════════════════════════════════════════════════════╗
 * ║                    WHY DO WE NEED THIS FILE?                    ║
 * ╠══════════════════════════════════════════════════════════════════╣
 * ║ An interface defines the "contract" (pun intended) between      ║
 * ║ the outside world and our protocol. It lists:                   ║
 * ║   - All functions others can call                               ║
 * ║   - All events that get emitted                                 ║
 * ║   - All custom errors that can be thrown                        ║
 * ║                                                                 ║
 * ║ Think of it like a restaurant menu — it tells you WHAT you      ║
 * ║ can order, but not HOW the kitchen makes it.                    ║
 * ║                                                                 ║
 * ║ Benefits:                                                       ║
 * ║   1. Other contracts can interact with MiniAave without         ║
 * ║      knowing the full implementation                            ║
 * ║   2. We can swap out implementations without breaking callers   ║
 * ║   3. It serves as documentation for our protocol's API          ║
 * ╚══════════════════════════════════════════════════════════════════╝
 */
interface IMiniAave {
    /*//////////////////////////////////////////////////////////////
                               EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted when a user deposits ETH as collateral
    /// @param user The address of the depositor
    /// @param amount The amount of ETH deposited (in wei)
    /// @dev `indexed` allows efficient filtering of events by user address
    event Deposited(address indexed user, uint256 amount);

    /// @notice Emitted when a user withdraws their ETH collateral
    /// @param user The address of the withdrawer
    /// @param amount The amount of ETH withdrawn (in wei)
    event Withdrawn(address indexed user, uint256 amount);

    /// @notice Emitted when a user borrows MUSD against their collateral
    /// @param user The address of the borrower
    /// @param amount The amount of MUSD borrowed (in 18-decimal USD)
    event Borrowed(address indexed user, uint256 amount);

    /// @notice Emitted when a user repays their MUSD debt
    /// @param user The address of the repayer
    /// @param amount The amount of MUSD repaid (in 18-decimal USD)
    event Repaid(address indexed user, uint256 amount);

    /// @notice Emitted when a liquidator liquidates an unhealthy position
    /// @param liquidator The address of the liquidator
    /// @param borrower The address of the user being liquidated
    /// @param debtRepaid The amount of MUSD debt the liquidator repaid
    /// @param collateralSeized The amount of ETH collateral seized (including bonus)
    event Liquidated(
        address indexed liquidator,
        address indexed borrower,
        uint256 debtRepaid,
        uint256 collateralSeized
    );

    /*//////////////////////////////////////////////////////////////
                             CUSTOM ERRORS
    //////////////////////////////////////////////////////////////*/

    /**
     * SOLIDITY CONCEPT: Custom Errors
     *
     * Custom errors are cheaper than require(condition, "string") because:
     *   - Error strings are stored as bytes in the contract bytecode (expensive!)
     *   - Custom errors use only 4 bytes (the selector) — saves gas on deployment AND on revert
     *
     * Convention: ContractName__ErrorDescription
     * Example: MiniAave__NeedsMoreThanZero()
     */

    /// @notice Thrown when a user tries to deposit/borrow/repay zero amount
    error MiniAave__NeedsMoreThanZero();

    /// @notice Thrown when an ETH transfer fails (e.g., to a contract without receive())
    error MiniAave__TransferFailed();

    /// @notice Thrown when an action (borrow/withdraw) would make the user's health factor < 1
    error MiniAave__BreaksHealthFactor(uint256 healthFactor);

    /// @notice Thrown when trying to liquidate a user whose health factor is still >= 1
    error MiniAave__HealthFactorOk();

    /// @notice Thrown when a user tries to withdraw more ETH than they deposited
    error MiniAave__InsufficientCollateral();

    /// @notice Thrown when a user tries to repay more MUSD than they owe
    error MiniAave__InsufficientDebt();

    /// @notice Thrown when the liquidation would require seizing more collateral than the user has
    error MiniAave__NotEnoughCollateralToSeize();

    /*//////////////////////////////////////////////////////////////
                           EXTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Deposit ETH as collateral into the protocol
    /// @dev Must send ETH with the transaction (msg.value > 0)
    function deposit() external payable;

    /// @notice Withdraw ETH collateral from the protocol
    /// @param amount The amount of ETH to withdraw (in wei)
    /// @dev Will revert if withdrawal would break health factor
    function withdraw(uint256 amount) external;

    /// @notice Borrow MUSD stablecoin against deposited ETH collateral
    /// @param amount The amount of MUSD to borrow (in 18-decimal USD)
    /// @dev Limited by collateral ratio (75% of collateral value)
    function borrow(uint256 amount) external;

    /// @notice Repay MUSD debt (partial or full repayment)
    /// @param amount The amount of MUSD to repay (in 18-decimal USD)
    /// @dev User must have approved MiniAave to spend their MUSD first
    function repay(uint256 amount) external;

    /// @notice Liquidate an unhealthy user's position
    /// @param borrower The address of the user to liquidate
    /// @param debtAmountToRepay The amount of MUSD debt to repay on behalf of borrower
    /// @dev Liquidator receives collateral + 5% bonus
    function liquidate(address borrower, uint256 debtAmountToRepay) external;

    /*//////////////////////////////////////////////////////////////
                            VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Get a user's health factor
    /// @param user The address to check
    /// @return healthFactor The health factor (1e18 = healthy threshold)
    function getHealthFactor(address user) external view returns (uint256 healthFactor);

    /// @notice Get the USD value of a user's deposited ETH collateral
    /// @param user The address to check
    /// @return collateralValueUsd The collateral value in 18-decimal USD
    function getCollateralValue(address user) external view returns (uint256 collateralValueUsd);

    /// @notice Get the amount of MUSD a user has borrowed
    /// @param user The address to check
    /// @return borrowedAmount The borrowed amount in 18-decimal USD
    function getBorrowedAmount(address user) external view returns (uint256 borrowedAmount);

    /// @notice Get the maximum additional MUSD a user can still borrow
    /// @param user The address to check
    /// @return maxBorrowable The max additional borrowable amount in 18-decimal USD
    function getMaxBorrowable(address user) external view returns (uint256 maxBorrowable);

    /// @notice Get a comprehensive view of a user's position
    /// @param user The address to check
    /// @return collateralEth The amount of ETH deposited (in wei)
    /// @return collateralValueUsd The USD value of collateral (18 decimals)
    /// @return borrowedAmount The MUSD debt (18 decimals)
    /// @return healthFactor The current health factor (1e18 scale)
    /// @return maxBorrowable The additional amount that can be borrowed
    function getUserPosition(address user)
        external
        view
        returns (
            uint256 collateralEth,
            uint256 collateralValueUsd,
            uint256 borrowedAmount,
            uint256 healthFactor,
            uint256 maxBorrowable
        );
}
