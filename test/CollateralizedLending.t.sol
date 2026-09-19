// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {CollateralizedLending, IMockOracle} from "../src/CollateralizedLending.sol";
import {MockOracle} from "../src/MockOracle.sol";
import {MockToken} from "../src/MockToken.sol";

contract CollateralizedLendingTest is Test {
    CollateralizedLending public lendingMarket;
    MockOracle public oracle;
    MockToken public collateralToken;
    MockToken public borrowToken;

    address public alice = address(0x3);
    address public liquidator = address(0x4);

    function setUp() public {
        vm.warp(10_000_000); // Set fixed baseline block.timestamp environment

        collateralToken = new MockToken("Wrapped Ether", "WETH", 1_000_000 * 10 ** 18);
        borrowToken = new MockToken("USD Coin", "USDC", 1_000_000 * 10 ** 18);
        oracle = new MockOracle();

   lendingMarket = new CollateralizedLending(collateralToken, borrowToken, IMockOracle(address(oracle)));



        // Standard Asset Price Initializations: WETH = $2000, USDC = $1
        oracle.setPrice(address(collateralToken), 2000 * 10 ** 18, block.timestamp);
        oracle.setPrice(address(borrowToken), 1 * 10 ** 18, block.timestamp);

        // Distribute token inventory pools
        collateralToken.transfer(alice, 10 * 10 ** 18);
        borrowToken.transfer(address(lendingMarket), 100_000 * 10 ** 18);
        borrowToken.transfer(liquidator, 50_000 * 10 ** 18);

        // Authorize allowance parameters
        vm.prank(alice);
        collateralToken.approve(address(lendingMarket), type(uint256).max);

        vm.prank(liquidator);
        borrowToken.approve(address(lendingMarket), type(uint256).max);
    }

    function test_HealthyBorrowFlow() public {
        vm.startPrank(alice);
        lendingMarket.depositCollateral(4 * 10 ** 18); // 4 WETH deposited = $8000 collateral base value
        lendingMarket.borrowAssets(2000 * 10 ** 18);  // Borrow $2000 USDC cleanly inside safe bounds
        vm.stopPrank();

        assertEq(lendingMarket.principalBorrowed(alice), 2000 * 10 ** 18);
        assertEq(borrowToken.balanceOf(alice), 2000 * 10 ** 18);
    }

    function test_InterestAccrualViaTimeWarping() public {
        vm.startPrank(alice);
        lendingMarket.depositCollateral(4 * 10 ** 18);
        lendingMarket.borrowAssets(2000 * 10 ** 18);
        vm.stopPrank();

        // Warp forward exactly one complete active financial year period
        vm.warp(block.timestamp + 365 days);

        // Recalculating debt bounds tracking interest at 10% APY rate metrics
        uint256 totalDebt = lendingMarket.getDebtOwed(alice);
        assertEq(totalDebt, 2200 * 10 ** 18); // Expected: 2000 + 200 interest tokens
    }

    function test_Revert_OverBorrowLimitEnforcement() public {
        vm.startPrank(alice);
        lendingMarket.depositCollateral(1 * 10 ** 18); // 1 WETH = $2000. 75% LTV capacity value = $1500 max limits

        vm.expectRevert(CollateralizedLending.BorrowLimitExceeded.selector);
        lendingMarket.borrowAssets(1501 * 10 ** 18); // Fails checking structural constraint boundaries by 1 token
        vm.stopPrank();
    }

    function test_LiquidationPipelineOnPriceDrop() public {
        vm.startPrank(alice);
        lendingMarket.depositCollateral(2 * 10 ** 18); // 2 WETH = $4000 value base
        lendingMarket.borrowAssets(1500 * 10 ** 18);  // Borrow $1500 USDC
        vm.stopPrank();

        // Simulate market volatility: WETH price crashes from $2000 down to $900
        oracle.setPrice(address(collateralToken), 900 * 10 ** 18, block.timestamp);

        // Position check: $1800 collateral value makes the $1500 debt exceed the 80% liquidation threshold
        assertTrue(lendingMarket.isLiquidable(alice));

        // Execute liquidation
        uint256 debtToCover = 500 * 10 ** 18;
        vm.prank(liquidator);
        lendingMarket.liquidate(alice, debtToCover);

        // Confirm debt reduction
        assertTrue(lendingMarket.principalBorrowed(alice) < 1500 * 10 ** 18);
    }

    function test_Revert_StaleOraclePriceEnforcement() public {
        vm.startPrank(alice);
        lendingMarket.depositCollateral(2 * 10 ** 18);
        lendingMarket.borrowAssets(1000 * 10 ** 18);
        vm.stopPrank();

        // Warp out of safe runtime synchronization threshold bounds (Max = 1 hour)
        vm.warp(block.timestamp + 2 hours);

        vm.prank(alice);
        vm.expectRevert(CollateralizedLending.StaleOraclePrice.selector);
        lendingMarket.borrowAssets(100 * 10 ** 18);
    }
}
