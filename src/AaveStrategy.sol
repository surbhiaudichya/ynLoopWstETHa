// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Vault} from "lib/yieldnest-vault/src/Vault.sol";
import {IERC20Detailed} from "./interfaces/aave-v3/IERC20Detailed.sol";
import {IPool} from "./interfaces/aave-v3/IPool.sol";
import {IWETH} from "./interfaces/aave-v3/IWETH.sol";
import {ISwapRouter02} from "./interfaces/aave-v3/ISwapRouter02.sol";
import {IDebtToken} from "./interfaces/aave-v3/IDebtToken.sol";

/**
 * @title AaveStrategy
 * @author Surbhi Audichya
 * @notice This contract is a strategy for Aave. It is responsible for looping deposited assets and managing debt and collateral.
 * The strategy focuses on WETH/wstETH pair and allows depositing WETH as collateral which then used for looping strategy using aave v3 WETH/ wstETH pool.
 * looping utilize the same collateral multiple times, resulting in a higher yield from a larger principal.
 */
contract AaveStrategy is Vault {
    IPool private constant pool;
    IERC20 private constant weth;
    IERC20 private constant wstETH;
    ISwapRouter02 private constant router;
    address private constant wstEthDebtToken;

    // Events for tracking
    event Deposit(address indexed caller, uint256 assetAmount, uint256 shares, address indexed receiver);
    event Borrow(address indexed caller, uint256 amountToBorrow, uint256 borrowedAmount);
    event Swap(address indexed caller, uint256 amountIn, uint256 amountOut);
    event Withdraw(address indexed caller, uint256 assetAmount, uint256 shares, address indexed receiver);
    event Unwind(address indexed caller, uint256 repaidAmount, uint256 withdrawnAmount);

    /**
     * @dev Constructor to initialize the strategy contract with required addresses.
     * @param _pool The address of the Aave pool.
     * @param _weth The address of WETH token.
     * @param _wstETH The address of wstETH token.
     * @param _uniSwapRouter_02 The address of Uniswap V3 Router for swapping.
     * @param _wstEthDebtToken The address of the wstETH debt token.
     */
    constructor(address _pool, address _weth, address _wstETH, address _uniSwapRouter_02, address _wstEthDebtToken) {
        pool = IPool(_pool);
        weth = IERC20(_weth);
        wstETH = IERC20(_wstETH);
        router = ISwapRouter02(_uniSwapRouter_02);
        wstEthDebtToken = _wstEthDebtToken;
    }

    receive() external payable {}

    /**
     * @notice Internal function to handle deposits and looping strategy.
     * @param asset_ The address of the asset.
     * @param caller The address of the caller (who deposits).
     * @param receiver The address of the receiver (who gets the shares).
     * @param assetAmount The amount of assets to deposit.
     * @param shares The amount of shares to mint.
     * @param baseAssets The base asset conversion of shares.
     *
     * @dev Assumptions:
     * - The caller is always same as msg.sender.
     * - Asset is WETH (wrapped Ether).
     * - The looping strategy executes 3 iterations for simplicity.
     * - This strategy assumes incentivized pools, as borrowing APR is typically higher than lending APR in non-incentivized pools.
     * - Slippage concerns are not considered for simplicity.
     */
    function _deposit(
        address asset_,
        address caller,
        address receiver,
        uint256 assetAmount,
        uint256 shares,
        uint256 baseAssets
    ) internal virtual override onlyAllocator {
        super._deposit(asset_, caller, receiver, assetAmount, shares, baseAssets);
        _looping(assetAmount, caller);

        // Emit deposit event
        emit Deposit(caller, assetAmount, shares, receiver);
    }

    /**
     * @notice Executes the looping strategy for a fixed number of iterations.
     * @param initialAmount The initial amount of WETH to loop.
     * @param caller The address of the msg.sender.
     *
     * @dev Assumptions:
     * - The borrowing limit for wstETH is 75% of the available ETH balance.
     * - The loop runs for a fixed number of iterations (3).
     * - wstETH is swapped for WETH in a single hop using Uniswap.
     * - No slippage concerns (for simplicity, `amountOutMin` is hardcoded to 1).
     * - This strategy works best in incentivized pools where lending APR is higher than borrowing APR.
     */
    function _looping(uint256 initialAmount, address caller) internal {
        uint256 amount = initialAmount;
        uint256 iterations = 3; // Define the number of looping iterations

        for (uint256 i = 0; i < iterations; i++) {
            // Approve Aave Pool to spend WETH
            weth.approve(address(pool), amount);

            // Supply WETH to Aave
            pool.supply(weth, amount, caller, 0);

            // Calculate the maximum amount of wstETH to borrow
            (, uint256 availableBorrowsETH,,,,) = IPool(pool).getUserAccountData(caller);
            uint256 amountToBorrow = availableBorrowsETH * 75 / 100; // Borrow up to 75% of available limit

            uint256 previousAmount = weth.balanceOf(caller);

            // Ensure delegation is sufficient for the contract to borrow on behalf of the caller
            require(
                IDebtToken(wstEthDebtToken).borrowAllowance(caller, address(this)) >= amountToBorrow,
                "Insufficient delegation"
            );

            // Borrow wstETH from Aave
            pool.borrow(wstETH, amountToBorrow, 2, 0, caller); // 2 represents variable interest rate mode

            uint256 amountOutMin = 1; // for simplicity
            swapExactInputSingleHop(amountToBorrow, amountOutMin, caller);

            // Emit borrow event
            emit Borrow(caller, amountToBorrow, weth.balanceOf(caller) - previousAmount);

            // Update amount for the next iteration
            uint256 actualAmount = weth.balanceOf(caller);
            amount = actualAmount - previousAmount;
        }

        // Supply last swapped WETH from borrowed wstETH
        weth.approve(address(pool), amount);
        pool.supply(weth, amount, caller, 0);
    }

    /**
     * @notice Internal function to swap WETH for wstETH using a single-hop Uniswap trade.
     * @param amountIn The amount of WETH to swap.
     * @param amountOutMin The minimum amount of wstETH to receive (slippage tolerance is not considered).
     * @param caller The address of the caller.
     *
     * @dev Assumptions:
     * - The swap router is correctly configured with the necessary liquidity.
     * - `amountOutMin` is a minimal value and no complex slippage calculation is considered.
     * - The contract has already been approved to spend WETH.
     */
    function swapExactInputSingleHop(uint256 amountIn, uint256 amountOutMin, address caller) internal {
        // Transfer WETH from the user to the strategy
        require(weth.transferFrom(caller, address(this), amountIn), "Transfer failed");

        weth.approve(address(router), amountIn);

        ISwapRouter02.ExactInputSingleParams memory params = ISwapRouter02.ExactInputSingleParams({
            tokenIn: address(weth),
            tokenOut: address(wstETH),
            fee: 3000,
            recipient: address(this),
            amountIn: amountIn,
            amountOutMinimum: amountOutMin,
            sqrtPriceLimitX96: 0
        });

        router.exactInputSingle(params);

        // Emit swap event
        emit Swap(caller, amountIn, wstETH.balanceOf(address(this)));
    }

    /**
     * @notice Allows the user to delegate credit to the strategy contract.
     * @param debtToken The address of the variable debt token of wstETH.
     * @param amount The amount of credit to delegate.
     *
     * @dev Assumptions:
     * - The user is allowed to delegate credit to the contract.
     * - The debt token supports the approveDelegation method.
     * - The contract will use this delegation to borrow on behalf of the user.
     */
    function delegateCredit(address debtToken, uint256 amount) external {
        // Allow the contract to borrow on behalf of the user
        IDebtToken(debtToken).approveDelegation(address(this), amount);
    }

    /**
     * @notice Internal function to handle withdrawals and unwinding the position.
     * @param caller The address of the caller.
     * @param receiver The address of the receiver.
     * @param owner The address of the owner of the shares.
     * @param assetAmount The amount of assets to withdraw.
     * @param shareAmount The equivalent amount of shares.
     * @return shares The amount of shares withdrawn.
     *
     * @dev Assumptions:
     * - Only the owner can initiate a withdrawal of assets.
     * - The caller is not allowed to do partial withdraw amount of assets held.
     * - The health factor and collateral ratio are not taken into account here (assuming it's always safe to withdraw).
     * - Unwinding is based on the assumption that the lending interest rates were consistently higher than the borrowing rates.
     * - Profit calculations are not handled in this contract for simplicity.
     */
    function withdraw(uint256 assetAmount, address receiver, address owner)
        public
        virtual
        override
        nonReentrant
        returns (uint256 shares)
    {
        if (paused()) {
            revert Paused();
        }

        // Ensure the caller is the owner of the shares
        if (msg.sender != owner) {
            revert("Caller is not the owner");
        }

        shares = address(this).balanceOf(msg.sender);

        // Preview the amount of assets that would be received for the given shares
        uint256 actualAssetAmount = previewRedeem(shares);

        VaultStorage storage vaultStorage = _getVaultStorage();
        _subTotalAssets(actualAssetAmount);

        // Burn shares before withdrawing the assets
        _burn(owner, shares);

        // Emit withdraw event
        emit Withdraw(msg.sender, assetAmount, shares, receiver);

        _unwinding();

        return shares;
    }

    /**
     * @notice Unwinds the user's position by repaying debt and withdrawing collateral.
     *
     * @dev Assumptions:
     * - The caller's should be msg.sender holding debt token and aToken.
     * - The debt is repaid to Aave before the collateral is withdrawn.
     * - The strategy assumes that lending interest rates were consistently higher than borrowing rates.
     * - The caller's debt token is used to repay the debt.
     * - The contract avoid complex unwinding logic, profit calculations, or partial withdraw.
     */
    function _unwinding() internal {
        uint256 amountToRepay = wstETH.balanceOf(address(this));

        // Approve the Aave pool to withdraw collateral and repay the debt
        wstETH.approve(address(pool), amountToRepay);

        // Repay debt and withdraw collateral from Aave
        pool.repay(wstETH, amountToRepay, 2, address(this)); // 2 represents variable rate mode
        uint256 amountWithdrawn = pool.withdraw(wstETH, amountToRepay, address(this));

        // Emit unwinding event
        emit Unwind(msg.sender, amountToRepay, amountWithdrawn);
    }
}
