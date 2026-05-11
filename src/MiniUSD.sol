// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title MiniUSD (MUSD)
 * @author Mini Aave Team (Educational Project)
 * @notice A simple ERC20 stablecoin that represents borrowed debt in MiniAave
 *
 * ╔══════════════════════════════════════════════════════════════════╗
 * ║                    WHY DO WE NEED THIS FILE?                    ║
 * ╠══════════════════════════════════════════════════════════════════╣
 * ║ In real Aave, when you borrow, you receive actual tokens        ║
 * ║ (like USDC or DAI). Our MiniUSD serves the same purpose:       ║
 * ║                                                                 ║
 * ║   1. User deposits ETH as collateral                            ║
 * ║   2. User borrows → MiniAave MINTS MUSD tokens to user         ║
 * ║   3. User repays → MiniAave BURNS the MUSD tokens              ║
 * ║                                                                 ║
 * ║ Only the MiniAave contract (the owner) can mint and burn.       ║
 * ║ This ensures no one can create fake debt or erase real debt.    ║
 * ╚══════════════════════════════════════════════════════════════════╝
 *
 * SOLIDITY CONCEPT: Inheritance
 * ─────────────────────────────────────────────────────
 * `is ERC20, ERC20Burnable, Ownable` means MiniUSD inherits
 * ALL functions and state from these three contracts:
 *
 *   ERC20 → gives us transfer(), balanceOf(), approve(), etc.
 *   ERC20Burnable → gives us burn() and burnFrom()
 *   Ownable → gives us onlyOwner modifier and ownership tracking
 *
 * We don't need to rewrite any of that logic — we just inherit it!
 */
contract MiniUSD is ERC20, ERC20Burnable, Ownable {
    /*//////////////////////////////////////////////////////////////
                             CUSTOM ERRORS
    //////////////////////////////////////////////////////////////*/

    /// @notice Thrown when trying to mint zero tokens
    error MiniUSD__MustBeMoreThanZero();

    /// @notice Thrown when trying to mint to the zero address
    error MiniUSD__NotZeroAddress();

    /// @notice Thrown when trying to burn more tokens than owned
    error MiniUSD__BurnAmountExceedsBalance();

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Creates the MiniUSD token and sets the owner (MiniAave contract)
     * @param initialOwner The address that will own this token (should be MiniAave)
     *
     * HOW IT WORKS:
     *   - ERC20("MiniUSD", "MUSD") sets the token name and symbol
     *   - Ownable(initialOwner) sets who can mint/burn
     *   - No initial supply is minted — tokens are only created when users borrow
     *
     * WHY THE OWNER MATTERS:
     *   The owner (MiniAave contract) is the ONLY address allowed to mint and burn.
     *   This is critical for security — if anyone could mint MUSD, they could
     *   create unlimited debt tokens and steal collateral.
     */
    constructor(address initialOwner) ERC20("MiniUSD", "MUSD") Ownable(initialOwner) {}

    /*//////////////////////////////////////////////////////////////
                           EXTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Mint new MUSD tokens (only callable by MiniAave contract)
     * @param to The address to receive the minted tokens
     * @param amount The number of tokens to mint
     * @return success Whether the mint was successful
     *
     * WHEN IS THIS CALLED?
     *   When a user borrows from MiniAave:
     *   1. User calls MiniAave.borrow(750e18) → "I want to borrow $750"
     *   2. MiniAave checks: does user have enough collateral? ✓
     *   3. MiniAave calls MiniUSD.mint(user, 750e18) → mints 750 MUSD to user
     *   4. User now has 750 MUSD in their wallet (real ERC20 tokens!)
     *
     * SECURITY: Only the owner (MiniAave) can call this.
     * If anyone could mint, they'd create free money.
     */
    function mint(address to, uint256 amount) external onlyOwner returns (bool) {
        if (to == address(0)) revert MiniUSD__NotZeroAddress();
        if (amount <= 0) revert MiniUSD__MustBeMoreThanZero();

        // _mint is an internal function from OpenZeppelin's ERC20
        // It increases `to`'s balance and the total supply
        _mint(to, amount);
        return true;
    }

    /**
     * @notice Burn MUSD tokens from a specific address (only callable by MiniAave)
     * @param from The address whose tokens will be burned
     * @param amount The number of tokens to burn
     *
     * WHEN IS THIS CALLED?
     *   When a user repays their debt:
     *   1. User approves MiniAave to spend their MUSD
     *   2. User calls MiniAave.repay(750e18)
     *   3. MiniAave transfers MUSD from user to itself
     *   4. MiniAave calls MiniUSD.burnFrom(miniAave, 750e18)
     *   5. The MUSD tokens are destroyed, reducing total supply
     *
     * Also called during liquidation when a liquidator repays someone else's debt.
     */
    function burnTokens(address from, uint256 amount) external onlyOwner {
        if (amount <= 0) revert MiniUSD__MustBeMoreThanZero();
        if (amount > balanceOf(from)) revert MiniUSD__BurnAmountExceedsBalance();

        // We call the internal _burn function directly since we're the owner
        // This bypasses the need for allowance checks (the owner is trusted)
        _burn(from, amount);
    }
}
