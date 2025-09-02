// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "../lib/openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {IPool} from "../lib/aave-v3-core/contracts/interfaces/IPool.sol";
import {IAToken} from "../lib/aave-v3-core/contracts/interfaces/IAToken.sol";
import {DataTypes} from "../lib/aave-v3-core/contracts/protocol/libraries/types/DataTypes.sol";
import {IAaveV3Vault} from "./interfaces/IAaveV3Vault.sol";
import {WadRayMath} from "../lib/aave-v3-core/contracts/protocol/libraries/math/WadRayMath.sol";
import {PercentageMath} from "../lib/aave-v3-core/contracts/protocol/libraries/math/PercentageMath.sol";

contract AaveV3Vault is IAaveV3Vault, ReentrancyGuard {
    using SafeERC20 for IERC20;

    //TODO: Add a method to withdraw aTokens because they are tradable

    uint256 private constant VARIABLE_RATE_MODE = 2;

    /// @notice Aave variable rate mode from DataTypes
    uint256 private constant VARIABLE_INTEREST_RATE =
        uint256(DataTypes.InterestRateMode.VARIABLE);
    /// @notice Minimum health factor threshold (1.00 in WAD)
    uint256 private constant MIN_HEALTH_FACTOR = WadRayMath.WAD; // 1.00 in WAD; can set > WadRayMath.WAD for safety buffer
    /// @notice Borrow buffer percentage (95% of available borrows)
    uint256 private constant BORROW_BUFFER_BPS = 9_500; // 95% of available borrows
    /// @notice Basis points denominator from Aave PercentageMath
    uint256 private constant BPS_DENOM = PercentageMath.PERCENTAGE_FACTOR;
    /// @notice WAD constant from Aave WadRayMath
    uint256 private constant WAD = WadRayMath.WAD;
    /// @notice RAY constant from Aave WadRayMath
    uint256 private constant RAY = WadRayMath.RAY;

    struct AssetData {
        uint256 totalSupplyShares; // sum of all users' supply shares for this asset
        uint256 totalDebtShares; // sum of all users' variable debt shares for this asset
        address aToken; // interest bearing token from Aave
        address variableDebtToken; // variable debt token from Aave
        bool initialized;
    }

    IPool public immutable POOL;

    mapping(address => AssetData) public assets; // asset => data

    // user => asset => shares
    mapping(address => mapping(address => uint256)) public supplySharesOf;
    mapping(address => mapping(address => uint256)) public debtSharesOf; // variable debt only

    constructor(address pool) {
        if (pool == address(0)) revert ZeroAddress();
        POOL = IPool(pool);
    }

    function deposit(
        address asset,
        uint256 amount
    ) external override returns (uint256) {
        if (amount == 0) revert ZeroAmount();
        _ensureInitialized(asset);

        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
        _safeApproveWithReset(asset, address(POOL), amount);

        uint256 totalBefore = _totalSupplyAssets(asset);
        AssetData storage a = assets[asset];

        // Interact with Aave
        POOL.supply(asset, amount, address(this), 0);

        uint256 sharesEarned = IAToken(a.aToken).scaledBalanceOf(
            address(this)
        ) - totalBefore;

        a.totalSupplyShares += sharesEarned;
        supplySharesOf[msg.sender][asset] += sharesEarned;

        emit Deposit(msg.sender, asset, amount, sharesEarned);

        return sharesEarned;
    }

    // TODO: fix these

    // function withdraw(
    //     address asset,
    //     uint256 amount
    // ) external override returns (uint256) {
    //     if (amount == 0) revert ZeroAmount();
    //     _ensureInitialized(asset);

    //     AssetData storage a = assets[asset];
    //     uint256 totalAssets = _totalSupplyAssets(asset);
    //     // shares = ceil(assets * totalShares / totalAssets)
    //     shares = _mulDivUp(amount, a.totalSupplyShares, totalAssets);
    //     uint256 userShares = supplySharesOf[msg.sender][asset];
    //     if (shares > userShares) revert InsufficientShares();

    //     // Burn shares first (effects)
    //     supplySharesOf[msg.sender][asset] = userShares - shares;
    //     a.totalSupplyShares -= shares;

    //     // Withdraw from Aave directly to user (interactions)
    //     uint256 withdrawn = POOL.withdraw(asset, amount, msg.sender);
    //     // Aave might withdraw slightly less if dust rounding; re-sync by recomputing shares with actual amount if needed
    //     if (withdrawn != amount) {
    //         // Adjust back if withdrawn less: re-mint the delta shares to user to avoid silent loss
    //         uint256 adjShares = _mulDivUp(
    //             amount - withdrawn,
    //             a.totalSupplyShares + shares,
    //             totalAssets
    //         ); // use prev totals
    //         supplySharesOf[msg.sender][asset] += adjShares;
    //         a.totalSupplyShares += adjShares;
    //         shares -= adjShares;
    //         amount = withdrawn;
    //     }

    //     emit Withdraw(msg.sender, asset, amount, shares);
    // }

    // function borrow(
    //     address asset,
    //     uint256 amount
    // ) external override returns (uint256 shares) {
    //     if (amount == 0) revert ZeroAmount();
    //     _ensureInitialized(asset);
    //     AssetData storage a = assets[asset];

    //     uint256 totalDebtBefore = totalDebtAssets(asset);
    //     shares = (a.totalDebtShares == 0 || totalDebtBefore == 0)
    //         ? amount
    //         : (amount * a.totalDebtShares) / totalDebtBefore;

    //     // Interact with Aave (borrow transfers funds to this contract)
    //     POOL.borrow(asset, amount, VARIABLE_RATE_MODE, 0, address(this));

    //     // Bookkeeping
    //     a.totalDebtShares += shares;
    //     debtSharesOf[msg.sender][asset] += shares;

    //     // Send borrowed funds to user
    //     IERC20(asset).safeTransfer(msg.sender, amount);

    //     emit Borrow(msg.sender, asset, amount, shares);
    // }

    // function repay(
    //     address asset,
    //     uint256 amount
    // ) external override returns (uint256 repaid, uint256 sharesBurned) {
    //     if (amount == 0) revert ZeroAmount();
    //     _ensureInitialized(asset);
    //     AssetData storage a = assets[asset];

    //     // Clamp to user's current debt to prevent overpaying others' debt.
    //     uint256 userDebt = debtAssetsOf(msg.sender, asset);
    //     if (amount > userDebt) amount = userDebt;

    //     // Pull funds and approve
    //     IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
    //     _safeApproveWithReset(asset, address(POOL), amount);

    //     uint256 totalDebtBefore = totalDebtAssets(asset);
    //     repaid = POOL.repay(asset, amount, VARIABLE_RATE_MODE, address(this));

    //     // Burn proportional shares based on pre-repay totals
    //     if (repaid > 0) {
    //         sharesBurned = (a.totalDebtShares == 0 || totalDebtBefore == 0)
    //             ? 0
    //             : (repaid * a.totalDebtShares) / totalDebtBefore;

    //         uint256 userShares = debtSharesOf[msg.sender][asset];
    //         if (sharesBurned > userShares) {
    //             sharesBurned = userShares; // safety for rounding
    //         }
    //         debtSharesOf[msg.sender][asset] = userShares - sharesBurned;
    //         a.totalDebtShares -= sharesBurned;
    //     }

    //     emit Repay(msg.sender, asset, repaid, sharesBurned);
    // }

    function _totalSupplyAssets(address asset) private view returns (uint256) {
        AssetData storage assetData = assets[asset];
        if (!assetData.initialized) return 0;
        return IAToken(assetData.aToken).scaledBalanceOf(address(this));
    }

    function _ensureInitialized(address asset) internal {
        AssetData storage a = assets[asset];
        if (a.initialized) return;

        DataTypes.ReserveData memory reserveData = POOL.getReserveData(asset);
        if (
            reserveData.aTokenAddress == address(0) ||
            reserveData.variableDebtTokenAddress == address(0)
        ) {
            revert InvalidAsset();
        }
        a.aToken = reserveData.aTokenAddress;
        a.variableDebtToken = reserveData.variableDebtTokenAddress;
        a.initialized = true;
    }

    // TODO: this can be public if the caller is the user
    function _getUserSupplyBalance(
        address user,
        address asset
    ) private view returns (uint256) {
        uint256 userShares = supplySharesOf[user][asset];
        if (userShares == 0) return 0;
        uint256 li = POOL.getReserveNormalizedIncome(asset);
        return (userShares * li) / RAY;
    }

    // TODO: this can be public if the caller is the user
    function _getUserBorrowBalance(
        address user,
        address asset
    ) private view returns (uint256) {
        uint256 userShares = debtSharesOf[user][asset];
        if (userShares == 0) return 0;
        uint256 di = POOL.getReserveNormalizedVariableDebt(asset);
        return (userShares * di) / RAY;
    }

    function _safeApprove(address token, address to, uint256 value) internal {
        (bool success, bytes memory data) = token.call(
            abi.encodeWithSelector(IERC20.approve.selector, to, value)
        );
        require(
            success && (data.length == 0 || abi.decode(data, (bool))),
            "SA"
        );
    }

    function _safeApproveWithReset(
        address token,
        address spender,
        uint256 amount
    ) internal {
        uint256 currentAllowance = IERC20(token).allowance(
            address(this),
            spender
        );
        if (currentAllowance != amount) {
            if (currentAllowance != 0) {
                _safeApprove(token, spender, 0);
            }
            _safeApprove(token, spender, amount);
        }
    }
}
