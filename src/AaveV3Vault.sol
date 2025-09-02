// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPool} from "../lib/aave-v3-core/contracts/interfaces/IPool.sol";
import {DataTypes} from "../lib/aave-v3-core/contracts/protocol/libraries/types/DataTypes.sol";
import {IAaveV3Vault} from "./interfaces/IAaveV3Vault.sol";

contract AaveV3Vault is IAaveV3Vault {
    uint256 private constant VARIABLE_RATE_MODE = 2;

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
        POOL = IPool(pool);
    }

    function deposit(
        address asset,
        uint256 amount
    ) external override returns (uint256 shares) {
        if (amount == 0) revert ZeroAmount();
        _ensureInitialized(asset);

        // Pull tokens
        _safeTransferFrom(asset, msg.sender, address(this), amount);
        _safeApprove(asset, address(POOL), amount);

        // Compute shares before mutating totals
        uint256 totalAssets = totalSupplyAssets(asset);
        AssetData storage a = assets[asset];
        shares = (a.totalSupplyShares == 0 || totalAssets == 0)
            ? amount
            : (amount * a.totalSupplyShares) / totalAssets;

        // Interact with Aave
        POOL.supply(asset, amount, address(this), 0);

        // Mint internal shares
        a.totalSupplyShares += shares;
        supplySharesOf[msg.sender][asset] += shares;

        emit Deposit(msg.sender, asset, amount, shares);
    }

    function withdraw(
        address asset,
        uint256 amount
    ) external override returns (uint256 shares) {
        if (amount == 0) revert ZeroAmount();
        _ensureInitialized(asset);

        AssetData storage a = assets[asset];
        uint256 totalAssets = totalSupplyAssets(asset);
        // shares = ceil(assets * totalShares / totalAssets)
        shares = _mulDivUp(amount, a.totalSupplyShares, totalAssets);
        uint256 userShares = supplySharesOf[msg.sender][asset];
        if (shares > userShares) revert InsufficientShares();

        // Burn shares first (effects)
        supplySharesOf[msg.sender][asset] = userShares - shares;
        a.totalSupplyShares -= shares;

        // Withdraw from Aave directly to user (interactions)
        uint256 withdrawn = POOL.withdraw(asset, amount, msg.sender);
        // Aave might withdraw slightly less if dust rounding; re-sync by recomputing shares with actual amount if needed
        if (withdrawn != amount) {
            // Adjust back if withdrawn less: re-mint the delta shares to user to avoid silent loss
            uint256 adjShares = _mulDivUp(
                amount - withdrawn,
                a.totalSupplyShares + shares,
                totalAssets
            ); // use prev totals
            supplySharesOf[msg.sender][asset] += adjShares;
            a.totalSupplyShares += adjShares;
            shares -= adjShares;
            amount = withdrawn;
        }

        emit Withdraw(msg.sender, asset, amount, shares);
    }

    function borrow(
        address asset,
        uint256 amount
    ) external override returns (uint256 shares) {
        if (amount == 0) revert ZeroAmount();
        _ensureInitialized(asset);
        AssetData storage a = assets[asset];

        uint256 totalDebtBefore = totalDebtAssets(asset);
        shares = (a.totalDebtShares == 0 || totalDebtBefore == 0)
            ? amount
            : (amount * a.totalDebtShares) / totalDebtBefore;

        // Interact with Aave (borrow transfers funds to this contract)
        POOL.borrow(asset, amount, VARIABLE_RATE_MODE, 0, address(this));

        // Bookkeeping
        a.totalDebtShares += shares;
        debtSharesOf[msg.sender][asset] += shares;

        // Send borrowed funds to user
        _safeTransfer(asset, msg.sender, amount);

        emit Borrow(msg.sender, asset, amount, shares);
    }

    function repay(
        address asset,
        uint256 amount
    ) external override returns (uint256 repaid, uint256 sharesBurned) {
        if (amount == 0) revert ZeroAmount();
        _ensureInitialized(asset);
        AssetData storage a = assets[asset];

        // Clamp to user's current debt to prevent overpaying others' debt.
        uint256 userDebt = debtAssetsOf(msg.sender, asset);
        if (amount > userDebt) amount = userDebt;

        // Pull funds and approve
        _safeTransferFrom(asset, msg.sender, address(this), amount);
        _safeApprove(asset, address(POOL), amount);

        uint256 totalDebtBefore = totalDebtAssets(asset);
        repaid = POOL.repay(asset, amount, VARIABLE_RATE_MODE, address(this));

        // Burn proportional shares based on pre-repay totals
        if (repaid > 0) {
            sharesBurned = (a.totalDebtShares == 0 || totalDebtBefore == 0)
                ? 0
                : (repaid * a.totalDebtShares) / totalDebtBefore;

            uint256 userShares = debtSharesOf[msg.sender][asset];
            if (sharesBurned > userShares) {
                sharesBurned = userShares; // safety for rounding
            }
            debtSharesOf[msg.sender][asset] = userShares - sharesBurned;
            a.totalDebtShares -= sharesBurned;
        }

        emit Repay(msg.sender, asset, repaid, sharesBurned);
    }

    function totalSupplyAssets(
        address asset
    ) public view override returns (uint256) {
        AssetData storage a = assets[asset];
        if (!a.initialized) return 0;
        return IERC20(a.aToken).balanceOf(address(this));
    }

    function totalDebtAssets(
        address asset
    ) public view override returns (uint256) {
        AssetData storage a = assets[asset];
        if (!a.initialized) return 0;
        return IERC20(a.variableDebtToken).balanceOf(address(this));
    }

    function supplyAssetsOf(
        address user,
        address asset
    ) external view override returns (uint256) {
        AssetData storage a = assets[asset];
        uint256 tAssets = totalSupplyAssets(asset);
        if (a.totalSupplyShares == 0 || tAssets == 0) return 0;
        return (supplySharesOf[user][asset] * tAssets) / a.totalSupplyShares;
    }

    function debtAssetsOf(
        address user,
        address asset
    ) public view override returns (uint256) {
        AssetData storage a = assets[asset];
        uint256 tDebt = totalDebtAssets(asset);
        if (a.totalDebtShares == 0 || tDebt == 0) return 0;
        return (debtSharesOf[user][asset] * tDebt) / a.totalDebtShares;
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

    function _mulDivUp(
        uint256 x,
        uint256 y,
        uint256 d
    ) internal pure returns (uint256) {
        return (x * y + d - 1) / d; // safe for our inputs; 0-division guarded by callers
    }

    function _safeTransferFrom(
        address token,
        address from,
        address to,
        uint256 amount
    ) internal {
        (bool success, bytes memory data) = token.call(
            abi.encodeWithSelector(
                IERC20.transferFrom.selector,
                from,
                to,
                amount
            )
        );
        require(
            success && (data.length == 0 || abi.decode(data, (bool))),
            "Transfer failed"
        );
    }

    function _safeTransfer(address token, address to, uint256 amount) internal {
        (bool success, bytes memory data) = token.call(
            abi.encodeWithSelector(IERC20.transfer.selector, to, amount)
        );
        require(
            success && (data.length == 0 || abi.decode(data, (bool))),
            "Transfer failed"
        );
    }

    function _safeApprove(
        address token,
        address spender,
        uint256 amount
    ) internal {
        // Reset approval to 0 first to prevent approval race condition attacks
        // Some tokens (like USDT) require allowance to be 0 before setting a new value
        (bool success, bytes memory data) = token.call(
            abi.encodeWithSelector(IERC20.approve.selector, spender, 0)
        );
        require(
            success && (data.length == 0 || abi.decode(data, (bool))),
            "Approve reset failed"
        );

        if (amount > 0) {
            (success, data) = token.call(
                abi.encodeWithSelector(IERC20.approve.selector, spender, amount)
            );
            require(
                success && (data.length == 0 || abi.decode(data, (bool))),
                "Approve failed"
            );
        }
    }
}
