// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {YieldVault} from "../src/YieldVault.sol";
import {MockToken} from "../src/MockToken.sol";

contract YieldVaultTest is Test {
    YieldVault public vault;
    MockToken public asset;

    address public feeRecipient = address(0x2);
    address public alice = address(0x3);
    address public bob = address(0x4);
    address public strategy = address(0x5);

    uint256 public constant PERFORMANCE_FEE = 1000; // 10%

    function setUp() public {
        // Deploy Underlying ERC-20 Asset
        asset = new MockToken("Dai Stablecoin", "DAI", 1_000_000 * 10 ** 18);

        // Deploy Vault
        vault = new YieldVault(asset, "Vaulted DAI", "vDAI", feeRecipient, PERFORMANCE_FEE);

        // Fund accounts
        asset.transfer(alice, 10_000 * 10 ** 18);
        asset.transfer(bob, 10_000 * 10 ** 18);
        asset.transfer(strategy, 50_000 * 10 ** 18);

        // Max out approvals for easier transfer interactions
        vm.prank(alice);
        asset.approve(address(vault), type(uint256).max);

        vm.prank(bob);
        asset.approve(address(vault), type(uint256).max);

        vm.prank(strategy);
        asset.approve(address(vault), type(uint256).max);
    }

    // --- Operational & Verification Flows ---

    function test_FirstDepositAndAccounting() public {
        uint256 depositAmount = 100 * 10 ** 18;

        vm.prank(alice);
        uint256 shares = vault.deposit(depositAmount, alice);

        // On first deposit, assets == shares
        assertEq(shares, depositAmount);
        assertEq(vault.balanceOf(alice), depositAmount);
        assertEq(vault.totalAssets(), depositAmount);
    }

    function test_MultipleDepositorsAndYieldAccrual() public {
        // Alice deposits 1000 tokens
        vm.prank(alice);
        vault.deposit(1000 * 10 ** 18, alice);

        // Strategy harvests 200 tokens of pure yield gains
        vm.prank(strategy);
        vault.reportYieldGain(200 * 10 ** 18);

        // Bob now deposits 1000 tokens under the new dynamic asset share evaluation rates
        vm.prank(bob);
        uint256 bobShares = vault.deposit(1000 * 10 ** 18, bob);

        // Bob should receive fewer shares than Alice due to the increased yield base value
        assertTrue(bobShares < vault.balanceOf(alice));
    }

    function test_RoundingSafeBoundaries() public {
        vm.prank(alice);
        vault.deposit(1000, alice);

        // Preview withdrawal ensures rounding works in favor of the vault (rounds up on shares burned)
        uint256 assetsToWithdraw = 1;
        uint256 expectedSharesBurned = vault.previewWithdraw(assetsToWithdraw);
        
        assertEq(expectedSharesBurned, 1);
    }

    function test_PerformanceFeeCollection() public {
        vm.prank(alice);
        vault.deposit(1000 * 10 ** 18, alice);

        // Strategy submits a yield gain of 100 tokens
        vm.prank(strategy);
        vault.reportYieldGain(100 * 10 ** 18);

        // Recipient should hold minted performance fee representation shares
        uint256 feeShares = vault.balanceOf(feeRecipient);
        assertTrue(feeShares > 0);
    }

    // --- Invalid and Revert Enforcements ---

    function test_Revert_ZeroAssetDeposits() public {
        vm.prank(alice);
        vm.expectRevert(YieldVault.ZeroAssets.selector);
        vault.deposit(0, alice);
    }

    function test_Revert_OverWithdrawals() public {
        vm.prank(alice);
        vault.deposit(100 * 10 ** 18, alice);

        vm.prank(alice);
        vm.expectRevert(YieldVault.ExcessiveWithdrawal.selector);
        vault.withdraw(101 * 10 ** 18, alice, alice);
    }
}
