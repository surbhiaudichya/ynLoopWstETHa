# AaveStrategy Contract

## Overview

The `AaveStrategy` contract enables users to deposit WETH into Aave, loop it to borrow wstETH, and withdraw collateral while managing debt to maintain a healthy loan position. It integrates with the **YieldNest Vault** for efficient asset management.

## Key Features
- Deposit WETH, borrow wstETH, and earn rewards by leveraging Aave’s mechanisms.
- Withdraw collateral while repaying wstETH debt to ensure a healthy loan position.
- Supports swapping between WETH and wstETH via Uniswap.

## Vault Integration
The contract extends YieldNest's `Vault` to manage user deposits, shares, and assets. It tracks balances and ensures seamless asset management for deposits and withdrawals.

## Assumptions
- Looping works only in incentivized pools with lower borrowing rates than lending rates.
- Unwinding assumes lending rates are higher than borrowing rates.

## Events
- **Deposit**, **Borrow**, **Swap**, **Withdraw**, **Unwind**

## Installation & Usage
1. Install dependencies and deploy the contract with Aave and Uniswap addresses.
2. Interact with the contract for deposit, withdrawal, and looping strategy management.
