# Aave V3 Unified Vault

A pooled vault-style adapter that integrates with **Aave V3** as a single on-chain account on behalf of many users. Users receive internal **supply shares** and **debt shares** that automatically reflect interest accrual via Aave's aTokens and variable debt tokens.

> ⚠️ This is a reference implementation for learning/testing. It makes the **entire vault's collateral** available to secure any user's borrow (pooled risk). Review and harden before production.

---

## File tree

```
.
├── foundry.toml
├── README.md
├── src
│   ├── AaveV3UnifiedVault.sol
│   └── interfaces
│       ├── IAaveV3Pool.sol
│       ├── IAaveV3DataProvider.sol
│       └── IERC20.sol
├── test
│   ├── AaveV3UnifiedVault.t.sol
│   ├── mocks
│   │   ├── MockERC20.sol
│   │   ├── MockAToken.sol
│   │   ├── MockDebtToken.sol
│   │   ├── MockAavePool.sol
│   │   └── MockDataProvider.sol
│   └── TestHelpers.sol
└── script
    └── Deploy.s.sol
```

---

## Quickstart

```bash
# 1) Install Foundry if needed: https://book.getfoundry.sh/getting-started/installation
# 2) Init project
forge install
forge build
forge test -vv
```

## Live network testing (fork)

Replace the mocks with a mainnet fork test if you prefer to hit real Aave V3. Update `foundry.toml` with your `rpc_url` and write a fork test pointing to the network's `POOL` and `DATA_PROVIDER` addresses.

## Design notes

* **Single Aave account:** The vault calls Aave with `onBehalfOf = address(this)`, pooling collateral and debt.
* **Interest reflection:** Users hold **supply shares** and **debt shares**. Conversion uses current `aToken.balanceOf(this)` and `vDebt.balanceOf(this)`, so interest automatically flows into balances.
* **Variable rate only:** For brevity we use variable debt (mode = 2). Stable rate could be added similarly.
* **Safety:** Anyone can borrow; the whole pool's collateral backs it. That's appropriate for a pooled lending account but risky in production. Add ACLs, per-user LTV checks, or isolate positions if needed.
* **Rounding:** Withdraw uses round-up share conversion; deposit/borrow use round-down; repay burns proportionally by pre-repay totals.