// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IMiniAave} from "./interfaces/IMiniAave.sol";
import {OracleLib} from "./libraries/OracleLib.sol";
import {MiniUSD} from "./MiniUSD.sol";

/**
 * @title MiniAave
 * @author Mini Aave Team (Educational Project)
 * @notice A simplified Aave-inspired lending protocol for learning DeFi
 *
 * ╔══════════════════════════════════════════════════════════════════╗
 * ║                     WHAT IS THIS CONTRACT?                      ║
 * ╠══════════════════════════════════════════════════════════════════╣
 * ║ This is the CORE ENGINE of our Mini Aave protocol.              ║
 * ║ It handles ALL lending operations:                              ║
 * ║                                                                 ║
 * ║   DEPOSIT  → User sends ETH → we record their collateral       ║
 * ║   BORROW   → User gets MUSD → we record their debt             ║
 * ║   REPAY    → User returns MUSD → we reduce their debt          ║
 * ║   WITHDRAW → User gets ETH back → we reduce their collateral   ║
 * ║   LIQUIDATE → Someone repays another's debt → gets collateral  ║
 * ║                                                                 ║
 * ║ KEY CONCEPT: Overcollateralization                              ║
 * ║ ─────────────────────────────────────────────────────           ║
 * ║ Users must deposit MORE collateral than they borrow.            ║
 * ║ If collateral ratio = 75%, and you deposit $1000 ETH,          ║
 * ║ you can borrow at most $750 MUSD.                               ║
 * ║                                                                 ║
 * ║ This "buffer" protects the protocol from bad debt if ETH        ║
 * ║ price drops — there's always more collateral than debt.         ║
 * ╚══════════════════════════════════════════════════════════════════╝
 *
 * SECURITY PATTERN: Checks-Effects-Interactions (CEI)
 * ─────────────────────────────────────────────────────
 * Every state-changing function follows this order:
 *   1. CHECKS  → Validate inputs and conditions
 *   2. EFFECTS → Update our contract's state (storage)
 *   3. INTERACTIONS → Call external contracts or send ETH
 *
 * WHY? If we interact with external contracts BEFORE updating state,
 * a malicious contract could re-enter our function and exploit stale state.
 * This is called a "reentrancy attack" — CEI prevents it.
 */
contract MiniAave is IMiniAave, ReentrancyGuard {
    /*//////////////////////////////////////////////////////////////
                    USING LIBRARY FOR TYPE
    //////////////////////////////////////////////////////////////*/

    /// @dev Attach OracleLib functions to AggregatorV3Interface
    /// This lets us call: s_priceFeed.getLatestPrice() instead of OracleLib.getLatestPrice(s_priceFeed)
    using OracleLib for AggregatorV3Interface;

    /*//////////////////////////////////////////////////////////////
                              CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Maximum Loan-to-Value ratio (75%)
    /// @dev User can borrow up to 75% of their collateral value
    /// Example: $1000 collateral → max borrow = $750
    uint256 private constant COLLATERAL_RATIO = 75;

    /// @notice Liquidation threshold (80%)
    /// @dev Position becomes liquidatable when debt > 80% of collateral
    /// The 5% gap between LTV(75%) and threshold(80%) gives users a buffer
    uint256 private constant LIQUIDATION_THRESHOLD = 80;

    /// @notice Bonus collateral given to liquidators (5%)
    /// @dev Incentivizes liquidators to keep the protocol healthy
    /// If liquidator repays $100 debt, they receive $105 worth of collateral
    uint256 private constant LIQUIDATION_BONUS = 5;

    /// @notice The minimum health factor before liquidation (1.0 in 18-decimal)
    /// @dev Health factor < 1e18 → position is unhealthy → can be liquidated
    uint256 private constant MIN_HEALTH_FACTOR = 1e18;

    /// @notice Precision for math operations (18 decimals)
    uint256 private constant PRECISION = 1e18;

    /// @notice Percentage precision (we use 100 as the denominator)
    uint256 private constant PERCENTAGE_PRECISION = 100;

    /*//////////////////////////////////////////////////////////////
                          STATE VARIABLES
    //////////////////////////////////////////////////////////////*/

    /**
     * SOLIDITY CONCEPT: immutable
     * ─────────────────────────────────────────────────────
     * `immutable` variables are set in the constructor and can NEVER change.
     * They cost zero gas to read (stored in bytecode, not storage).
     *
     * Convention: prefix with `i_` to signal immutability
     */

    /// @notice The Chainlink ETH/USD price feed
    AggregatorV3Interface private immutable i_priceFeed;

    /// @notice The MiniUSD stablecoin token contract
    MiniUSD private immutable i_miniUsd;

    /**
     * SOLIDITY CONCEPT: Storage Variables
     * ─────────────────────────────────────────────────────
     * `storage` variables live permanently on the blockchain.
     * Reading costs 2100 gas (cold) or 100 gas (warm).
     * Writing costs 20000 gas (new) or 5000 gas (update).
     *
     * Convention: prefix with `s_` to signal storage
     *
     * mappings are perfect for per-user data because they offer
     * O(1) lookup — checking any user's balance costs the same gas.
     */

    /// @notice ETH collateral deposited per user (in wei)
    mapping(address user => uint256 amount) private s_collateralDeposited;

    /// @notice MUSD debt per user (in 18-decimal USD)
    mapping(address user => uint256 amount) private s_amountBorrowed;

    /*//////////////////////////////////////////////////////////////
                              MODIFIERS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Ensures the amount is greater than zero
     * @dev Used on deposit, borrow, repay, and liquidate to prevent no-op transactions
     *
     * SOLIDITY CONCEPT: Modifiers
     * ─────────────────────────────────────────────────────
     * Modifiers are reusable checks that run BEFORE a function body.
     * The `_;` means "now run the actual function code."
     *
     * Without modifier: every function would need `if (amount == 0) revert ...;`
     * With modifier: just add `moreThanZero(amount)` to the function signature
     */
    modifier moreThanZero(uint256 amount) {
        if (amount == 0) {
            revert MiniAave__NeedsMoreThanZero();
        }
        _;
    }

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Initialize MiniAave with a price feed and MUSD token
     * @param priceFeed The Chainlink ETH/USD price feed address
     * @param miniUsd The MiniUSD token address (ownership must be transferred to this contract)
     */
    constructor(address priceFeed, address miniUsd) {
        i_priceFeed = AggregatorV3Interface(priceFeed);
        i_miniUsd = MiniUSD(miniUsd);
    }

    /*//////////////////////////////////////////////////////////////
                         EXTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Deposit ETH as collateral
     * @dev CEI Pattern: Check msg.value > 0 → Update balance → (no external call needed)
     *
     * FLOW:
     *   1. User sends ETH with this transaction (msg.value)
     *   2. We add it to their collateral balance
     *   3. Emit Deposited event for off-chain tracking
     *
     * NOTE: `payable` keyword is required to accept ETH.
     * Without it, sending ETH to this function would revert.
     */
    function deposit() external payable moreThanZero(msg.value) nonReentrant {
        // EFFECTS: Update the user's collateral balance in storage
        s_collateralDeposited[msg.sender] += msg.value;

        // EVENT: Emit for off-chain tracking (frontends, indexers, etc.)
        emit Deposited(msg.sender, msg.value);
    }

    /**
     * @notice Withdraw ETH collateral
     * @param amount The amount of ETH to withdraw (in wei)
     *
     * CEI Pattern:
     *   CHECKS  → amount > 0, user has enough collateral
     *   EFFECTS → reduce collateral balance
     *   INTERACTIONS → send ETH to user
     *   FINAL CHECK → ensure health factor is still OK
     *
     * WHY CHECK HEALTH FACTOR?
     *   If a user has borrowed MUSD and tries to withdraw too much collateral,
     *   it could make their position undercollateralized. We prevent that.
     */
    function withdraw(uint256 amount) external moreThanZero(amount) nonReentrant {
        // CHECKS: Does the user have enough collateral?
        if (amount > s_collateralDeposited[msg.sender]) {
            revert MiniAave__InsufficientCollateral();
        }

        // EFFECTS: Reduce collateral balance BEFORE sending ETH (CEI!)
        s_collateralDeposited[msg.sender] -= amount;

        // EVENT
        emit Withdrawn(msg.sender, amount);

        // INTERACTIONS: Send ETH to user
        (bool success,) = payable(msg.sender).call{value: amount}("");
        if (!success) revert MiniAave__TransferFailed();

        // FINAL CHECK: If user has outstanding debt, make sure they're still healthy
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    /**
     * @notice Borrow MUSD stablecoin against deposited ETH collateral
     * @param amount The amount of MUSD to borrow (in 18-decimal USD)
     *
     * CEI Pattern:
     *   CHECKS  → amount > 0 (modifier)
     *   EFFECTS → increase debt balance
     *   INTERACTIONS → mint MUSD tokens to borrower
     *   FINAL CHECK → ensure health factor is still OK
     *
     * EXAMPLE:
     *   User deposited 1 ETH (worth $2000)
     *   Max borrow = $2000 * 75% = $1500
     *   User calls borrow(1000e18) → borrows $1000 MUSD
     *   Health factor = ($2000 * 80%) / $1000 = 1.6 → healthy ✓
     */
    function borrow(uint256 amount) external moreThanZero(amount) nonReentrant {
        // EFFECTS: Record the new debt
        s_amountBorrowed[msg.sender] += amount;

        // INTERACTIONS: Mint MUSD tokens to the borrower
        // The borrower receives real ERC20 tokens they can trade, hold, etc.
        bool success = i_miniUsd.mint(msg.sender, amount);
        if (!success) revert MiniAave__TransferFailed();

        // FINAL CHECK: Did this borrow break the health factor?
        // If so, revert the entire transaction (undo the debt and mint)
        _revertIfHealthFactorIsBroken(msg.sender);

        // EVENT
        emit Borrowed(msg.sender, amount);
    }

    /**
     * @notice Repay MUSD debt (partial or full)
     * @param amount The amount of MUSD to repay (in 18-decimal USD)
     *
     * CEI Pattern:
     *   CHECKS  → amount > 0, amount <= debt
     *   EFFECTS → reduce debt balance
     *   INTERACTIONS → transfer MUSD from user, then burn it
     *
     * IMPORTANT: User must call MUSD.approve(miniAaveAddress, amount) FIRST!
     * Without approval, the transferFrom will fail.
     *
     * WHY BURN THE TOKENS?
     *   When debt is repaid, the MUSD is no longer needed.
     *   Burning reduces the total supply, keeping MUSD's value stable.
     *   Think of it as: the "IOU" is destroyed when the loan is repaid.
     */
    function repay(uint256 amount) external moreThanZero(amount) nonReentrant {
        // CHECKS: Can't repay more than you owe
        if (amount > s_amountBorrowed[msg.sender]) {
            revert MiniAave__InsufficientDebt();
        }

        // EFFECTS: Reduce debt BEFORE external calls (CEI!)
        s_amountBorrowed[msg.sender] -= amount;

        // INTERACTIONS:
        // Step 1: Transfer MUSD from user to this contract
        bool success = IERC20(address(i_miniUsd)).transferFrom(msg.sender, address(this), amount);
        if (!success) revert MiniAave__TransferFailed();

        // Step 2: Burn the MUSD tokens (destroy them)
        i_miniUsd.burnTokens(address(this), amount);

        // EVENT
        emit Repaid(msg.sender, amount);
    }

    /**
     * @notice Liquidate an unhealthy borrower's position (partial liquidation)
     * @param borrower The address of the unhealthy borrower
     * @param debtAmountToRepay The amount of MUSD debt to repay on behalf of borrower
     *
     * ╔══════════════════════════════════════════════════════════════╗
     * ║                    HOW LIQUIDATION WORKS                     ║
     * ╠══════════════════════════════════════════════════════════════╣
     * ║                                                              ║
     * ║  1. Alice deposits 1 ETH ($2000) and borrows $1500 MUSD     ║
     * ║  2. ETH price drops to $1800                                 ║
     * ║  3. Health Factor = ($1800 * 80%) / $1500 = 0.96 (< 1.0!)  ║
     * ║  4. Bob (liquidator) sees Alice is liquidatable              ║
     * ║  5. Bob calls liquidate(alice, 750e18) → repays $750 debt   ║
     * ║  6. Bob receives: $750 + 5% bonus = $787.50 in ETH          ║
     * ║  7. Alice's debt is now $750, her collateral is reduced      ║
     * ║                                                              ║
     * ║  RESULT: Protocol is healthier, Bob made a profit,           ║
     * ║  Alice still has some collateral left.                       ║
     * ╚══════════════════════════════════════════════════════════════╝
     */
    function liquidate(
        address borrower,
        uint256 debtAmountToRepay
    ) external moreThanZero(debtAmountToRepay) nonReentrant {
        // CHECKS: Is the borrower actually unhealthy?
        uint256 startingHealthFactor = _healthFactor(borrower);
        if (startingHealthFactor >= MIN_HEALTH_FACTOR) {
            revert MiniAave__HealthFactorOk();
        }

        // CHECKS: Can't repay more than the borrower owes
        if (debtAmountToRepay > s_amountBorrowed[borrower]) {
            revert MiniAave__InsufficientDebt();
        }

        // Calculate how much ETH collateral to seize
        // Convert debt amount (USD) to ETH equivalent
        uint256 ethAmountFromDebt = i_priceFeed.getEthAmountFromUsd(debtAmountToRepay);

        // Add the liquidation bonus (5% extra reward for the liquidator)
        // bonus = ethAmountFromDebt * 5 / 100
        uint256 bonusCollateral = (ethAmountFromDebt * LIQUIDATION_BONUS) / PERCENTAGE_PRECISION;
        uint256 totalCollateralToSeize = ethAmountFromDebt + bonusCollateral;

        // CHECKS: Does the borrower have enough collateral to seize?
        if (totalCollateralToSeize > s_collateralDeposited[borrower]) {
            revert MiniAave__NotEnoughCollateralToSeize();
        }

        // EFFECTS: Update borrower's state
        s_amountBorrowed[borrower] -= debtAmountToRepay;
        s_collateralDeposited[borrower] -= totalCollateralToSeize;

        // INTERACTIONS:
        // Step 1: Transfer MUSD from liquidator to this contract
        bool success = IERC20(address(i_miniUsd)).transferFrom(msg.sender, address(this), debtAmountToRepay);
        if (!success) revert MiniAave__TransferFailed();

        // Step 2: Burn the repaid MUSD
        i_miniUsd.burnTokens(address(this), debtAmountToRepay);

        // Step 3: Send seized collateral (ETH) to liquidator
        (bool ethSuccess,) = payable(msg.sender).call{value: totalCollateralToSeize}("");
        if (!ethSuccess) revert MiniAave__TransferFailed();

        // EVENT
        emit Liquidated(msg.sender, borrower, debtAmountToRepay, totalCollateralToSeize);
    }

    /*//////////////////////////////////////////////////////////////
                     PRIVATE / INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Calculate a user's health factor
     * @param user The address to calculate for
     * @return The health factor (1e18 scale, < 1e18 = liquidatable)
     *
     * FORMULA:
     *   healthFactor = (collateralValueUsd * liquidationThreshold) / (debt * 100)
     *
     * EXAMPLE:
     *   collateral = $2000, debt = $1500, threshold = 80%
     *   healthFactor = ($2000 * 80) / ($1500 * 100) = 1.066... (> 1.0 → healthy)
     *
     * If ETH drops 15% → collateral = $1700
     *   healthFactor = ($1700 * 80) / ($1500 * 100) = 0.906... (< 1.0 → liquidatable!)
     *
     * WHY type(uint256).max WHEN NO DEBT?
     *   If a user has no debt, they can't be liquidated regardless of collateral.
     *   We return the maximum uint256 to represent "infinitely healthy."
     */
    function _healthFactor(address user) private view returns (uint256) {
        uint256 totalBorrowed = s_amountBorrowed[user];

        // No debt = infinitely healthy (can't divide by zero)
        if (totalBorrowed == 0) {
            return type(uint256).max;
        }

        uint256 collateralValueUsd = i_priceFeed.getUsdValue(s_collateralDeposited[user]);

        // (collateralValue * threshold * precision) / (debt * 100)
        // The extra PRECISION multiplication keeps our 18-decimal accuracy
        uint256 collateralAdjusted = (collateralValueUsd * LIQUIDATION_THRESHOLD) / PERCENTAGE_PRECISION;
        return (collateralAdjusted * PRECISION) / totalBorrowed;
    }

    /**
     * @notice Revert the transaction if a user's health factor is broken
     * @param user The address to check
     * @dev Called after borrow() and withdraw() to ensure the action didn't make things worse
     */
    function _revertIfHealthFactorIsBroken(address user) private view {
        uint256 userHealthFactor = _healthFactor(user);
        if (userHealthFactor < MIN_HEALTH_FACTOR) {
            revert MiniAave__BreaksHealthFactor(userHealthFactor);
        }
    }

    /*//////////////////////////////////////////////////////////////
                     PUBLIC VIEW / GETTER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IMiniAave
    function getHealthFactor(address user) external view returns (uint256) {
        return _healthFactor(user);
    }

    /// @inheritdoc IMiniAave
    function getCollateralValue(address user) external view returns (uint256) {
        return i_priceFeed.getUsdValue(s_collateralDeposited[user]);
    }

    /// @inheritdoc IMiniAave
    function getBorrowedAmount(address user) external view returns (uint256) {
        return s_amountBorrowed[user];
    }

    /// @inheritdoc IMiniAave
    function getMaxBorrowable(address user) external view returns (uint256) {
        uint256 collateralValueUsd = i_priceFeed.getUsdValue(s_collateralDeposited[user]);
        uint256 maxBorrow = (collateralValueUsd * COLLATERAL_RATIO) / PERCENTAGE_PRECISION;
        uint256 currentDebt = s_amountBorrowed[user];

        // If already borrowed more than max (price dropped), return 0
        if (currentDebt >= maxBorrow) return 0;
        return maxBorrow - currentDebt;
    }

    /// @inheritdoc IMiniAave
    function getUserPosition(address user)
        external
        view
        returns (
            uint256 collateralEth,
            uint256 collateralValueUsd,
            uint256 borrowedAmount,
            uint256 healthFactor,
            uint256 maxBorrowable
        )
    {
        collateralEth = s_collateralDeposited[user];
        collateralValueUsd = i_priceFeed.getUsdValue(collateralEth);
        borrowedAmount = s_amountBorrowed[user];
        healthFactor = _healthFactor(user);

        uint256 maxBorrow = (collateralValueUsd * COLLATERAL_RATIO) / PERCENTAGE_PRECISION;
        maxBorrowable = borrowedAmount >= maxBorrow ? 0 : maxBorrow - borrowedAmount;
    }

    /// @notice Get the raw ETH collateral deposited (in wei, not USD)
    function getCollateralDeposited(address user) external view returns (uint256) {
        return s_collateralDeposited[user];
    }

    /// @notice Get the MiniUSD token address
    function getMiniUsdAddress() external view returns (address) {
        return address(i_miniUsd);
    }

    /// @notice Get the Chainlink price feed address
    function getPriceFeedAddress() external view returns (address) {
        return address(i_priceFeed);
    }
}
