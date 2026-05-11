// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console2} from "forge-std/Test.sol";
import {DeployMiniAave} from "../../script/DeployMiniAave.s.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {MiniAave} from "../../src/MiniAave.sol";
import {IMiniAave} from "../../src/interfaces/IMiniAave.sol";
import {MiniUSD} from "../../src/MiniUSD.sol";
import {MockV3Aggregator} from "../mocks/MockV3Aggregator.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title MiniAaveTest
 * @notice Comprehensive test suite for the Mini Aave lending protocol
 *
 * TEST STRUCTURE:
 * ─────────────────────────────────────────────────────
 * 1. Deposit tests     → depositing ETH collateral
 * 2. Withdraw tests    → withdrawing ETH collateral
 * 3. Borrow tests      → borrowing MUSD against collateral
 * 4. Repay tests       → repaying MUSD debt
 * 5. Health factor tests → health factor calculations
 * 6. Liquidation tests → liquidating unhealthy positions
 * 7. View function tests → getter/helper function tests
 * 8. Edge case tests   → multi-user + full scenario walkthrough
 */
contract MiniAaveTest is Test {
    /*//////////////////////////////////////////////////////////////
                         LOCAL EVENT COPIES
    //////////////////////////////////////////////////////////////*/
    /// @dev Re-declared here because Solidity 0.8.20 can't emit InterfaceName.Event
    event Deposited(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);
    event Borrowed(address indexed user, uint256 amount);
    event Repaid(address indexed user, uint256 amount);
    event Liquidated(address indexed liquidator, address indexed borrower, uint256 debtRepaid, uint256 collateralSeized);

    /*//////////////////////////////////////////////////////////////
                          STATE VARIABLES
    //////////////////////////////////////////////////////////////*/

    MiniAave public miniAave;
    MiniUSD public miniUsd;
    HelperConfig public helperConfig;
    MockV3Aggregator public mockPriceFeed;

    /// @dev Test users created with Foundry's makeAddr() cheatcode
    address public ALICE = makeAddr("alice");
    address public BOB = makeAddr("bob");
    address public LIQUIDATOR = makeAddr("liquidator");

    /// @dev Test amounts
    uint256 public constant STARTING_ETH_BALANCE = 100 ether;
    uint256 public constant DEPOSIT_AMOUNT = 10 ether;
    uint256 public constant INITIAL_ETH_PRICE = 2000e8; // $2000 in 8 decimals (Chainlink format)

    /*//////////////////////////////////////////////////////////////
                               SETUP
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Runs before EVERY test function
     * @dev Deploys all contracts and funds test users
     *
     * FOUNDRY CONCEPT: setUp()
     * ─────────────────────────────────────────────────────
     * Foundry automatically calls setUp() before each test.
     * Each test gets a FRESH deployment — tests don't affect each other.
     * This is called "test isolation."
     */
    function setUp() public {
        // Deploy the full protocol using our deployment script
        DeployMiniAave deployer = new DeployMiniAave();
        (miniAave, helperConfig) = deployer.run();

        // Get references to deployed contracts
        miniUsd = MiniUSD(miniAave.getMiniUsdAddress());
        mockPriceFeed = MockV3Aggregator(miniAave.getPriceFeedAddress());

        // Fund test users with ETH using vm.deal (Foundry cheatcode)
        vm.deal(ALICE, STARTING_ETH_BALANCE);
        vm.deal(BOB, STARTING_ETH_BALANCE);
        vm.deal(LIQUIDATOR, STARTING_ETH_BALANCE);
    }

    /*//////////////////////////////////////////////////////////////
                           DEPOSIT TESTS
    //////////////////////////////////////////////////////////////*/

    function testDepositIncreasesCollateral() public {
        // Arrange & Act: Alice deposits 10 ETH
        vm.prank(ALICE);
        miniAave.deposit{value: DEPOSIT_AMOUNT}();

        // Assert: Her collateral balance should be 10 ETH
        uint256 deposited = miniAave.getCollateralDeposited(ALICE);
        assertEq(deposited, DEPOSIT_AMOUNT, "Collateral should match deposit");
    }

    function testDepositEmitsEvent() public {
        // We expect the Deposited event with alice's address and amount
        vm.expectEmit(true, false, false, true, address(miniAave));
        emit Deposited(ALICE, DEPOSIT_AMOUNT);

        vm.prank(ALICE);
        miniAave.deposit{value: DEPOSIT_AMOUNT}();
    }

    function testDepositRevertsWithZeroAmount() public {
        vm.prank(ALICE);
        vm.expectRevert(IMiniAave.MiniAave__NeedsMoreThanZero.selector);
        miniAave.deposit{value: 0}();
    }

    function testMultipleDepositsAccumulate() public {
        vm.startPrank(ALICE);
        miniAave.deposit{value: 5 ether}();
        miniAave.deposit{value: 3 ether}();
        vm.stopPrank();

        assertEq(miniAave.getCollateralDeposited(ALICE), 8 ether);
    }

    /*//////////////////////////////////////////////////////////////
                          WITHDRAW TESTS
    //////////////////////////////////////////////////////////////*/

    function testWithdrawReturnsEth() public {
        // Arrange: Alice deposits first
        vm.startPrank(ALICE);
        miniAave.deposit{value: DEPOSIT_AMOUNT}();

        uint256 balanceBefore = ALICE.balance;

        // Act: Withdraw half
        miniAave.withdraw(5 ether);
        vm.stopPrank();

        // Assert
        assertEq(miniAave.getCollateralDeposited(ALICE), 5 ether);
        assertEq(ALICE.balance, balanceBefore + 5 ether);
    }

    function testWithdrawFullBalance() public {
        vm.startPrank(ALICE);
        miniAave.deposit{value: DEPOSIT_AMOUNT}();
        miniAave.withdraw(DEPOSIT_AMOUNT);
        vm.stopPrank();

        assertEq(miniAave.getCollateralDeposited(ALICE), 0);
    }

    function testWithdrawRevertsIfInsufficientCollateral() public {
        vm.startPrank(ALICE);
        miniAave.deposit{value: 5 ether}();

        vm.expectRevert(IMiniAave.MiniAave__InsufficientCollateral.selector);
        miniAave.withdraw(10 ether); // Trying to withdraw more than deposited
        vm.stopPrank();
    }

    function testWithdrawRevertsWithZeroAmount() public {
        vm.prank(ALICE);
        vm.expectRevert(IMiniAave.MiniAave__NeedsMoreThanZero.selector);
        miniAave.withdraw(0);
    }

    function testWithdrawRevertsIfBreaksHealthFactor() public {
        vm.startPrank(ALICE);
        miniAave.deposit{value: DEPOSIT_AMOUNT}();

        // Borrow close to max — 10 ETH * $2000 * 75% = $15000
        miniAave.borrow(14000e18);

        // Try to withdraw most collateral → would break health factor
        vm.expectRevert(); // Will revert with MiniAave__BreaksHealthFactor
        miniAave.withdraw(9 ether);
        vm.stopPrank();
    }

    function testWithdrawEmitsEvent() public {
        vm.startPrank(ALICE);
        miniAave.deposit{value: DEPOSIT_AMOUNT}();

        vm.expectEmit(true, false, false, true, address(miniAave));
        emit Withdrawn(ALICE, 5 ether);
        miniAave.withdraw(5 ether);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                           BORROW TESTS
    //////////////////////////////////////////////////////////////*/

    function testBorrowMintsMusdToUser() public {
        vm.startPrank(ALICE);
        miniAave.deposit{value: DEPOSIT_AMOUNT}();

        // Borrow $5000 MUSD
        uint256 borrowAmount = 5000e18;
        miniAave.borrow(borrowAmount);
        vm.stopPrank();

        // Alice should have $5000 MUSD in her wallet
        assertEq(miniUsd.balanceOf(ALICE), borrowAmount);
        // Her debt should be recorded
        assertEq(miniAave.getBorrowedAmount(ALICE), borrowAmount);
    }

    function testBorrowMaxAmount() public {
        vm.startPrank(ALICE);
        miniAave.deposit{value: DEPOSIT_AMOUNT}();

        // Max borrow = 10 ETH * $2000 * 75% = $15,000
        uint256 maxBorrow = miniAave.getMaxBorrowable(ALICE);
        miniAave.borrow(maxBorrow);
        vm.stopPrank();

        assertEq(miniUsd.balanceOf(ALICE), maxBorrow);
        assertEq(miniAave.getMaxBorrowable(ALICE), 0);
    }

    function testBorrowRevertsIfExceedsCollateralRatio() public {
        vm.startPrank(ALICE);
        miniAave.deposit{value: DEPOSIT_AMOUNT}();

        // 10 ETH * $2000 = $20000 collateral
        // Health factor threshold = 80%, so max before liquidation = $20000 * 80% = $16000
        // Borrowing $16001 breaks the health factor (HF < 1.0)
        vm.expectRevert(); // MiniAave__BreaksHealthFactor
        miniAave.borrow(16001e18);
        vm.stopPrank();
    }

    function testBorrowRevertsWithZeroAmount() public {
        vm.prank(ALICE);
        vm.expectRevert(IMiniAave.MiniAave__NeedsMoreThanZero.selector);
        miniAave.borrow(0);
    }

    function testBorrowRevertsIfNoCollateral() public {
        // Alice has no deposits
        vm.prank(ALICE);
        vm.expectRevert(); // MiniAave__BreaksHealthFactor
        miniAave.borrow(1000e18);
    }

    function testBorrowEmitsEvent() public {
        vm.startPrank(ALICE);
        miniAave.deposit{value: DEPOSIT_AMOUNT}();

        vm.expectEmit(true, false, false, true, address(miniAave));
        emit Borrowed(ALICE, 5000e18);
        miniAave.borrow(5000e18);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                            REPAY TESTS
    //////////////////////////////////////////////////////////////*/

    function testRepayReducesDebt() public {
        vm.startPrank(ALICE);
        miniAave.deposit{value: DEPOSIT_AMOUNT}();
        miniAave.borrow(5000e18);

        // Approve MiniAave to spend MUSD
        miniUsd.approve(address(miniAave), 2000e18);
        miniAave.repay(2000e18);
        vm.stopPrank();

        assertEq(miniAave.getBorrowedAmount(ALICE), 3000e18);
        assertEq(miniUsd.balanceOf(ALICE), 3000e18); // 5000 - 2000 burned
    }

    function testRepayFullDebt() public {
        vm.startPrank(ALICE);
        miniAave.deposit{value: DEPOSIT_AMOUNT}();
        miniAave.borrow(5000e18);

        miniUsd.approve(address(miniAave), 5000e18);
        miniAave.repay(5000e18);
        vm.stopPrank();

        assertEq(miniAave.getBorrowedAmount(ALICE), 0);
        assertEq(miniUsd.balanceOf(ALICE), 0);
    }

    function testRepayRevertsIfMoreThanDebt() public {
        vm.startPrank(ALICE);
        miniAave.deposit{value: DEPOSIT_AMOUNT}();
        miniAave.borrow(5000e18);

        miniUsd.approve(address(miniAave), 6000e18);
        vm.expectRevert(IMiniAave.MiniAave__InsufficientDebt.selector);
        miniAave.repay(6000e18);
        vm.stopPrank();
    }

    function testRepayRevertsWithZeroAmount() public {
        vm.prank(ALICE);
        vm.expectRevert(IMiniAave.MiniAave__NeedsMoreThanZero.selector);
        miniAave.repay(0);
    }

    function testRepayEmitsEvent() public {
        vm.startPrank(ALICE);
        miniAave.deposit{value: DEPOSIT_AMOUNT}();
        miniAave.borrow(5000e18);

        miniUsd.approve(address(miniAave), 2000e18);

        vm.expectEmit(true, false, false, true, address(miniAave));
        emit Repaid(ALICE, 2000e18);
        miniAave.repay(2000e18);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                       HEALTH FACTOR TESTS
    //////////////////////////////////////////////////////////////*/

    function testHealthFactorIsMaxWhenNoDebt() public {
        vm.prank(ALICE);
        miniAave.deposit{value: DEPOSIT_AMOUNT}();

        uint256 hf = miniAave.getHealthFactor(ALICE);
        assertEq(hf, type(uint256).max, "No debt = max health factor");
    }

    function testHealthFactorDecreasesWithMoreDebt() public {
        vm.startPrank(ALICE);
        miniAave.deposit{value: DEPOSIT_AMOUNT}();

        miniAave.borrow(5000e18);
        uint256 hfAfterSmallBorrow = miniAave.getHealthFactor(ALICE);

        miniAave.borrow(5000e18);
        uint256 hfAfterMoreBorrow = miniAave.getHealthFactor(ALICE);
        vm.stopPrank();

        assertTrue(hfAfterMoreBorrow < hfAfterSmallBorrow, "More debt = lower health factor");
    }

    function testHealthFactorCalculation() public {
        vm.startPrank(ALICE);
        miniAave.deposit{value: DEPOSIT_AMOUNT}();
        miniAave.borrow(10000e18); // Borrow $10000
        vm.stopPrank();

        // Expected: ($20000 * 80%) / $10000 = 1.6 → 1.6e18
        uint256 hf = miniAave.getHealthFactor(ALICE);
        assertEq(hf, 1.6e18, "Health factor should be 1.6");
    }

    function testHealthFactorDropsWithPriceDecline() public {
        vm.startPrank(ALICE);
        miniAave.deposit{value: DEPOSIT_AMOUNT}();
        miniAave.borrow(10000e18);
        vm.stopPrank();

        uint256 hfBefore = miniAave.getHealthFactor(ALICE);

        // Price drops from $2000 to $1500
        mockPriceFeed.updateAnswer(1500e8);

        uint256 hfAfter = miniAave.getHealthFactor(ALICE);
        assertTrue(hfAfter < hfBefore, "Health factor should drop with price");

        // Expected: ($15000 * 80%) / $10000 = 1.2 → 1.2e18
        assertEq(hfAfter, 1.2e18);
    }

    /*//////////////////////////////////////////////////////////////
                        LIQUIDATION TESTS
    //////////////////////////////////////////////////////////////*/

    /// @dev Helper: set up Alice with a position that becomes liquidatable after price drop
    function _setupLiquidatablePosition() private {
        // Alice deposits 10 ETH ($20000) and borrows $14000
        vm.startPrank(ALICE);
        miniAave.deposit{value: DEPOSIT_AMOUNT}();
        miniAave.borrow(14000e18);
        vm.stopPrank();

        // Price crashes from $2000 → $1000
        // New collateral value: 10 ETH * $1000 = $10000
        // Health factor: ($10000 * 80%) / $14000 = 0.571 → LIQUIDATABLE
        mockPriceFeed.updateAnswer(1000e8);
    }

    /// @dev Helper: give the liquidator some MUSD to repay debt
    function _fundLiquidatorWithMusd(uint256 amount) private {
        // Liquidator needs MUSD to repay Alice's debt
        // They deposit ETH and borrow MUSD themselves
        vm.startPrank(LIQUIDATOR);
        miniAave.deposit{value: 50 ether}();
        miniAave.borrow(amount);
        miniUsd.approve(address(miniAave), amount);
        vm.stopPrank();
    }

    function testLiquidateUnhealthyPosition() public {
        _setupLiquidatablePosition();

        // Verify Alice is liquidatable
        uint256 hf = miniAave.getHealthFactor(ALICE);
        assertTrue(hf < 1e18, "Alice should be liquidatable");

        // Fund liquidator
        _fundLiquidatorWithMusd(7000e18);

        uint256 aliceDebtBefore = miniAave.getBorrowedAmount(ALICE);

        // Liquidator repays $7000 of Alice's debt
        vm.prank(LIQUIDATOR);
        miniAave.liquidate(ALICE, 7000e18);

        // Alice's debt should be reduced
        uint256 aliceDebtAfter = miniAave.getBorrowedAmount(ALICE);
        assertEq(aliceDebtAfter, aliceDebtBefore - 7000e18);
    }

    function testLiquidatorReceivesCollateralPlusBonus() public {
        _setupLiquidatablePosition();
        _fundLiquidatorWithMusd(7000e18);

        uint256 liquidatorEthBefore = LIQUIDATOR.balance;

        vm.prank(LIQUIDATOR);
        miniAave.liquidate(ALICE, 7000e18);

        uint256 liquidatorEthAfter = LIQUIDATOR.balance;
        uint256 ethReceived = liquidatorEthAfter - liquidatorEthBefore;

        // At $1000/ETH: $7000 debt = 7 ETH + 5% bonus = 7.35 ETH
        assertEq(ethReceived, 7.35 ether, "Liquidator should receive collateral + 5% bonus");
    }

    function testLiquidationReducesBorrowerCollateral() public {
        _setupLiquidatablePosition();
        _fundLiquidatorWithMusd(7000e18);

        uint256 aliceCollateralBefore = miniAave.getCollateralDeposited(ALICE);

        vm.prank(LIQUIDATOR);
        miniAave.liquidate(ALICE, 7000e18);

        uint256 aliceCollateralAfter = miniAave.getCollateralDeposited(ALICE);
        // 7 ETH + 5% bonus = 7.35 ETH seized
        assertEq(aliceCollateralAfter, aliceCollateralBefore - 7.35 ether);
    }

    function testLiquidationRevertsIfHealthFactorOk() public {
        // Alice has a healthy position
        vm.startPrank(ALICE);
        miniAave.deposit{value: DEPOSIT_AMOUNT}();
        miniAave.borrow(5000e18);
        vm.stopPrank();

        _fundLiquidatorWithMusd(1000e18);

        vm.prank(LIQUIDATOR);
        vm.expectRevert(IMiniAave.MiniAave__HealthFactorOk.selector);
        miniAave.liquidate(ALICE, 1000e18);
    }

    function testLiquidationRevertsIfDebtExceeded() public {
        _setupLiquidatablePosition();
        _fundLiquidatorWithMusd(20000e18);

        vm.prank(LIQUIDATOR);
        vm.expectRevert(IMiniAave.MiniAave__InsufficientDebt.selector);
        miniAave.liquidate(ALICE, 20000e18); // Alice only owes $14000
    }

    function testLiquidationEmitsEvent() public {
        _setupLiquidatablePosition();
        _fundLiquidatorWithMusd(7000e18);

        // 7000 USD / 1000 USD per ETH = 7 ETH + 5% = 7.35 ETH
        vm.expectEmit(true, true, false, true, address(miniAave));
        emit Liquidated(LIQUIDATOR, ALICE, 7000e18, 7.35 ether);

        vm.prank(LIQUIDATOR);
        miniAave.liquidate(ALICE, 7000e18);
    }

    /*//////////////////////////////////////////////////////////////
                       VIEW FUNCTION TESTS
    //////////////////////////////////////////////////////////////*/

    function testGetCollateralValue() public {
        vm.prank(ALICE);
        miniAave.deposit{value: DEPOSIT_AMOUNT}();

        // 10 ETH * $2000 = $20000
        uint256 value = miniAave.getCollateralValue(ALICE);
        assertEq(value, 20000e18);
    }

    function testGetMaxBorrowable() public {
        vm.prank(ALICE);
        miniAave.deposit{value: DEPOSIT_AMOUNT}();

        // 10 ETH * $2000 * 75% = $15000
        uint256 maxBorrow = miniAave.getMaxBorrowable(ALICE);
        assertEq(maxBorrow, 15000e18);
    }

    function testGetMaxBorrowableAfterBorrowing() public {
        vm.startPrank(ALICE);
        miniAave.deposit{value: DEPOSIT_AMOUNT}();
        miniAave.borrow(5000e18);
        vm.stopPrank();

        // $15000 max - $5000 borrowed = $10000 remaining
        assertEq(miniAave.getMaxBorrowable(ALICE), 10000e18);
    }

    function testGetUserPosition() public {
        vm.startPrank(ALICE);
        miniAave.deposit{value: DEPOSIT_AMOUNT}();
        miniAave.borrow(10000e18);
        vm.stopPrank();

        (
            uint256 collateralEth,
            uint256 collateralValueUsd,
            uint256 borrowedAmount,
            uint256 healthFactor,
            uint256 maxBorrowable
        ) = miniAave.getUserPosition(ALICE);

        assertEq(collateralEth, 10 ether);
        assertEq(collateralValueUsd, 20000e18);
        assertEq(borrowedAmount, 10000e18);
        assertEq(healthFactor, 1.6e18);
        assertEq(maxBorrowable, 5000e18); // $15000 - $10000
    }

    /*//////////////////////////////////////////////////////////////
                         EDGE CASE TESTS
    //////////////////////////////////////////////////////////////*/

    function testMultipleUsersIndependent() public {
        // Alice deposits 10 ETH
        vm.prank(ALICE);
        miniAave.deposit{value: 10 ether}();

        // Bob deposits 5 ETH
        vm.prank(BOB);
        miniAave.deposit{value: 5 ether}();

        assertEq(miniAave.getCollateralDeposited(ALICE), 10 ether);
        assertEq(miniAave.getCollateralDeposited(BOB), 5 ether);
        assertEq(miniAave.getCollateralValue(ALICE), 20000e18);
        assertEq(miniAave.getCollateralValue(BOB), 10000e18);
    }

    function testPriceCrashTriggersLiquidationEligibility() public {
        vm.startPrank(ALICE);
        miniAave.deposit{value: DEPOSIT_AMOUNT}();
        miniAave.borrow(14000e18);
        vm.stopPrank();

        // Before crash: HF = ($20000 * 80%) / $14000 = 1.142... → healthy
        assertTrue(miniAave.getHealthFactor(ALICE) >= 1e18);

        // ETH crashes 50%: $2000 → $1000
        mockPriceFeed.updateAnswer(1000e8);

        // After crash: HF = ($10000 * 80%) / $14000 = 0.571... → liquidatable!
        assertTrue(miniAave.getHealthFactor(ALICE) < 1e18);
    }

    /*//////////////////////////////////////////////////////////////
               FULL LIQUIDATION SCENARIO WALKTHROUGH
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice End-to-end liquidation scenario test
     *
     * SCENARIO:
     * 1. Alice deposits 10 ETH (worth $20,000 at $2000/ETH)
     * 2. Alice borrows $14,000 MUSD (close to the 75% max of $15,000)
     * 3. ETH price crashes to $1,000
     * 4. Alice's health factor drops below 1.0
     * 5. Bob (liquidator) repays $7,000 of Alice's debt
     * 6. Bob receives 7.35 ETH ($7,350 worth — $7,000 + 5% bonus)
     * 7. Verify final state
     */
    function testFullLiquidationScenario() public {
        console2.log("=== LIQUIDATION SCENARIO WALKTHROUGH ===");

        // Step 1: Alice deposits 10 ETH
        vm.prank(ALICE);
        miniAave.deposit{value: 10 ether}();
        console2.log("1. Alice deposited 10 ETH");
        console2.log("   Collateral value: $%s", miniAave.getCollateralValue(ALICE) / 1e18);

        // Step 2: Alice borrows $14,000 MUSD
        vm.prank(ALICE);
        miniAave.borrow(14000e18);
        console2.log("2. Alice borrowed $14,000 MUSD");
        console2.log("   Health factor: %s", miniAave.getHealthFactor(ALICE) / 1e16); // Display as xx.xx

        // Step 3: ETH price crashes to $1,000
        mockPriceFeed.updateAnswer(1000e8);
        console2.log("3. ETH PRICE CRASHED: $2,000 -> $1,000");
        console2.log("   New collateral value: $%s", miniAave.getCollateralValue(ALICE) / 1e18);

        uint256 aliceHf = miniAave.getHealthFactor(ALICE);
        console2.log("   New health factor: %s (BELOW 1.0 = LIQUIDATABLE!)", aliceHf);
        assertTrue(aliceHf < 1e18, "Alice should be liquidatable");

        // Step 4: Bob gets MUSD to liquidate
        // (Bob deposits ETH and borrows MUSD — at $1000/ETH he needs lots)
        vm.startPrank(BOB);
        miniAave.deposit{value: 50 ether}();
        miniAave.borrow(7000e18);
        miniUsd.approve(address(miniAave), 7000e18);
        vm.stopPrank();
        console2.log("4. Bob (liquidator) acquired 7,000 MUSD");

        // Record balances before liquidation
        uint256 bobEthBefore = BOB.balance;
        uint256 aliceCollateralBefore = miniAave.getCollateralDeposited(ALICE);
        uint256 aliceDebtBefore = miniAave.getBorrowedAmount(ALICE);

        // Step 5: Bob liquidates Alice
        vm.prank(BOB);
        miniAave.liquidate(ALICE, 7000e18);
        console2.log("5. Bob liquidated $7,000 of Alice's debt");

        // Step 6: Verify results
        uint256 bobEthAfter = BOB.balance;
        uint256 ethReceived = bobEthAfter - bobEthBefore;
        console2.log("6. Bob received %s ETH (includes 5%% bonus)", ethReceived / 1e18);

        assertEq(ethReceived, 7.35 ether, "Bob should receive 7.35 ETH");
        assertEq(miniAave.getBorrowedAmount(ALICE), aliceDebtBefore - 7000e18, "Alice debt reduced");
        assertEq(
            miniAave.getCollateralDeposited(ALICE),
            aliceCollateralBefore - 7.35 ether,
            "Alice collateral reduced"
        );

        console2.log("");
        console2.log("=== FINAL STATE ===");
        console2.log("Alice remaining debt: $%s", miniAave.getBorrowedAmount(ALICE) / 1e18);
        console2.log("Alice remaining collateral: %s ETH", miniAave.getCollateralDeposited(ALICE) / 1e18);
        console2.log("Alice health factor: %s", miniAave.getHealthFactor(ALICE));
        console2.log("Bob profit: 0.35 ETH ($350 at current price)");
    }
}
