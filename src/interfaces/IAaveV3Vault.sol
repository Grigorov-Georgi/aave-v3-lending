// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/**
 * @title IAaveV3Vault
 * @notice Interface for AaveV3Vault contract
 * @dev Defines the main functions for interacting with the Aave V3 lending vault
 */
interface IAaveV3Vault {
    event Deposit(
        address indexed user,
        address indexed asset,
        uint256 assets,
        uint256 shares
    );

    event Withdraw(
        address indexed user,
        address indexed asset,
        uint256 assets,
        uint256 shares
    );

    event Borrow(
        address indexed user,
        address indexed asset,
        uint256 assets,
        uint256 shares
    );

    event Repay(
        address indexed user,
        address indexed asset,
        uint256 assets,
        uint256 shares
    );

    error ZeroAddress();
    error ZeroAmount();
    error InsufficientShares();
    error InvalidAsset();

    /**
     * @notice Deposit tokens into the vault and receive shares
     * @param asset The address of the token to deposit
     * @param amount The amount of tokens to deposit
     * @return shares The amount of shares minted to the user
     */
    function deposit(
        address asset,
        uint256 amount
    ) external returns (uint256 shares);

    /**
     * @notice Withdraw tokens from the vault by burning shares
     * @param asset The address of the token to withdraw
     * @param amount The amount of tokens to withdraw
     * @return shares The amount of shares burned from the user
     */
    function withdraw(
        address asset,
        uint256 amount
    ) external returns (uint256 shares);

    /**
     * @notice Borrow tokens from the vault
     * @param asset The address of the token to borrow
     * @param amount The amount of tokens to borrow
     * @return shares The amount of debt shares minted to the user
     */
    function borrow(
        address asset,
        uint256 amount
    ) external returns (uint256 shares);

    /**
     * @notice Repay borrowed tokens to the vault
     * @param asset The address of the token to repay
     * @param amount The amount of tokens to repay
     * @return repaid The actual amount repaid to Aave
     * @return sharesBurned The amount of debt shares burned from the user
     */
    function repay(
        address asset,
        uint256 amount
    ) external returns (uint256 repaid, uint256 sharesBurned);

    /**
     * @notice Get the total supply assets for a given token
     * @param asset The address of the token
     * @return The total amount of assets supplied to the vault
     */
    function totalSupplyAssets(address asset) external view returns (uint256);

    /**
     * @notice Get the total debt assets for a given token
     * @param asset The address of the token
     * @return The total amount of debt for the token
     */
    function totalDebtAssets(address asset) external view returns (uint256);

    /**
     * @notice Get a user's supply assets for a given token
     * @param user The address of the user
     * @param asset The address of the token
     * @return The amount of assets the user has supplied
     */
    function supplyAssetsOf(
        address user,
        address asset
    ) external view returns (uint256);

    /**
     * @notice Get a user's debt assets for a given token
     * @param user The address of the user
     * @param asset The address of the token
     * @return The amount of debt the user owes
     */
    function debtAssetsOf(
        address user,
        address asset
    ) external view returns (uint256);

    /**
     * @notice Get a user's supply shares for a given token
     * @param user The address of the user
     * @param asset The address of the token
     * @return The amount of supply shares the user owns
     */
    function supplySharesOf(
        address user,
        address asset
    ) external view returns (uint256);

    /**
     * @notice Get a user's debt shares for a given token
     * @param user The address of the user
     * @param asset The address of the token
     * @return The amount of debt shares the user owes
     */
    function debtSharesOf(
        address user,
        address asset
    ) external view returns (uint256);
}
