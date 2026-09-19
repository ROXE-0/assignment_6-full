// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

interface IMockOracle {
    function getPrice(address token) external view returns (uint256 price, uint256 updatedAt);
}

contract CollateralizedLending is ReentrancyGuard {
    using SafeERC20 for IERC20;
    using Math for uint256;

    // --- Configuration Constants ---
    uint256 public constant COLLATERAL_FACTOR_BPS = 7500; // 75% LTV Maximum Limit
    uint256 public constant LIQUIDATION_THRESHOLD_BPS = 8000; // 80% Liquidation Threshold
    uint256 public constant LIQUIDATION_BONUS_BPS = 500;  // 5% Liquidator Incentive Bonus
    uint256 public constant INTEREST_RATE_BPS = 1000;    // 10% APY Interest Rate
    uint256 public constant SECONDS_PER_YEAR = 365 days;
    uint256 public constant STALE_PRICE_WINDOW = 1 hours;

    // --- State Variables ---
    IERC20 public immutable collateralToken;
    IERC20 public immutable borrowToken;
    IMockOracle public immutable oracle;

    mapping(address => uint256) public collateralBalances;
    mapping(address => uint256) public principalBorrowed;
    mapping(address => uint256) public lastInterestAccrualTime;

    // --- Events ---
    event CollateralDeposited(address indexed user, uint256 amount);
    event CollateralWithdrawn(address indexed user, uint256 amount);
    event AssetsBorrowed(address indexed user, uint256 amount);
    event DebtRepaid(address indexed user, uint256 amount);
    event PositionLiquidated(address indexed user, address indexed liquidator, uint256 debtRepaid, uint256 collateralSeized);

    // --- Custom Errors ---
    error InsufficientCollateral();
    error BorrowLimitExceeded();
    error PositionIsHealthy();
    error InsufficientDebtToRepay();
    error StaleOraclePrice();
    error InvalidPriceData();
    error TransferFailed();
    error ZeroAmount();

    constructor(IERC20 _collateralToken, IERC20 _borrowToken, IMockOracle _oracle) {
        collateralToken = _collateralToken;
        borrowToken = _borrowToken;
        oracle = _oracle;
    }

    // --- External / Public Views ---

    /**
     * @notice Computes a user's total active outstanding debt including accumulated compounding interest.
     */
    function getDebtOwed(address user) public view returns (uint256) {
        uint256 principal = principalBorrowed[user];
        if (principal == 0) return 0;

        uint256 timeElapsed = block.timestamp - lastInterestAccrualTime[user];
        if (timeElapsed == 0) return principal;

        // Simple interest accrual: Debt = Principal + (Principal * Rate * Time / Year)
        uint256 interest = principal.mulDiv(INTEREST_RATE_BPS * timeElapsed, 10000 * SECONDS_PER_YEAR, Math.Rounding.Floor);
        return principal + interest;
    }

    /**
     * @notice Validates structural health limits using token prices retrieved from the oracle.
     */
    function getAccountLiquidity(address user) public view returns (uint256 collateralValueUsd, uint256 borrowPowerUsd, uint256 totalDebtUsd) {
        (uint256 collateralPrice, uint256 collatUpdated) = oracle.getPrice(address(collateralToken));
        (uint256 borrowPrice, uint256 borrowUpdated) = oracle.getPrice(address(borrowToken));

        if (collateralPrice == 0 || borrowPrice == 0) revert InvalidPriceData();
        if (block.timestamp - collatUpdated > STALE_PRICE_WINDOW || block.timestamp - borrowUpdated > STALE_PRICE_WINDOW) {
            revert StaleOraclePrice();
        }

        collateralValueUsd = collateralBalances[user].mulDiv(collateralPrice, 10 ** 18, Math.Rounding.Floor);
        borrowPowerUsd = collateralValueUsd.mulDiv(COLLATERAL_FACTOR_BPS, 10000, Math.Rounding.Floor);
        totalDebtUsd = getDebtOwed(user).mulDiv(borrowPrice, 10 ** 18, Math.Rounding.Floor);
    }

    /**
     * @notice Checks whether a user position has dropped past the safe threshold parameter bounds.
     */
    function isLiquidable(address user) public view returns (bool) {
        (uint256 collateralValueUsd, , uint256 totalDebtUsd) = getAccountLiquidity(user);
        if (totalDebtUsd == 0) return false;
        
        uint256 maxSafeDebtUsd = collateralValueUsd.mulDiv(LIQUIDATION_THRESHOLD_BPS, 10000, Math.Rounding.Floor);
        return totalDebtUsd > maxSafeDebtUsd;
    }

    // --- Core Action Mechanics ---

    function depositCollateral(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        _accrueInterest(msg.sender);

        collateralBalances[msg.sender] += amount;
        emit CollateralDeposited(msg.sender, amount);

        collateralToken.safeTransferFrom(msg.sender, address(this), amount);
    }

    function withdrawCollateral(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        _accrueInterest(msg.sender);

        collateralBalances[msg.sender] -= amount;
        (, uint256 borrowPowerUsd, uint256 totalDebtUsd) = getAccountLiquidity(msg.sender);
        if (totalDebtUsd > borrowPowerUsd) revert InsufficientCollateral();

        emit CollateralWithdrawn(msg.sender, amount);
        collateralToken.safeTransfer(msg.sender, amount);
    }

    function borrowAssets(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        _accrueInterest(msg.sender);

        principalBorrowed[msg.sender] += amount;
        (, uint256 borrowPowerUsd, uint256 totalDebtUsd) = getAccountLiquidity(msg.sender);
        if (totalDebtUsd > borrowPowerUsd) revert BorrowLimitExceeded();

        emit AssetsBorrowed(msg.sender, amount);
        borrowToken.safeTransfer(msg.sender, amount);
    }

    function repayDebt(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        _accrueInterest(msg.sender);

        uint256 currentDebt = principalBorrowed[msg.sender];
        if (currentDebt == 0) revert InsufficientDebtToRepay();

        uint256 repaymentAmount = amount > currentDebt ? currentDebt : amount;
        principalBorrowed[msg.sender] -= repaymentAmount;

        emit DebtRepaid(msg.sender, repaymentAmount);
        borrowToken.safeTransferFrom(msg.sender, address(this), repaymentAmount);
    }

    /**
     * @notice Liquidates an underwater position by purchasing debt and receiving discounted collateral.
     */
    function liquidate(address user, uint256 debtToCover) external nonReentrant {
        _accrueInterest(user);
        if (!isLiquidable(user)) revert PositionIsHealthy();

        uint256 userDebt = principalBorrowed[user];
        uint256 maxCover = userDebt.mulDiv(5000, 10000, Math.Rounding.Floor); // Max 50% closing factor target bound
        uint256 actualCover = debtToCover > maxCover ? maxCover : debtToCover;
        if (actualCover == 0) revert ZeroAmount();

        (uint256 collateralPrice, ) = oracle.getPrice(address(collateralToken));
        (uint256 borrowPrice, ) = oracle.getPrice(address(borrowToken));

        // Calculate basic asset swap value metrics
        uint256 baseCollateralToSeize = actualCover.mulDiv(borrowPrice, collateralPrice, Math.Rounding.Floor);
        uint256 bonusCollateral = baseCollateralToSeize.mulDiv(LIQUIDATION_BONUS_BPS, 10000, Math.Rounding.Floor);
        uint256 totalCollateralSeized = baseCollateralToSeize + bonusCollateral;

        // Cap seizure parameters clean to current boundaries to prevent full protocol exploit failures
        if (totalCollateralSeized > collateralBalances[user]) {
            totalCollateralSeized = collateralBalances[user];
        }

        principalBorrowed[user] -= actualCover;
        collateralBalances[user] -= totalCollateralSeized;

        emit PositionLiquidated(user, msg.sender, actualCover, totalCollateralSeized);

        borrowToken.safeTransferFrom(msg.sender, address(this), actualCover);
        collateralToken.safeTransfer(msg.sender, totalCollateralSeized);
    }

    // --- Private Helper Routine ---

    function _accrueInterest(address user) private {
        principalBorrowed[user] = getDebtOwed(user);
        lastInterestAccrualTime[user] = block.timestamp;
    }
}
