// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {TokenLaunchpad} from "../src/TokenLaunchpad.sol";
import {MockToken} from "../src/MockToken.sol";

contract TokenLaunchpadTest is Test {
    TokenLaunchpad public launchpad;
    MockToken public token;

    address public creator = address(0x1);
    address public feeRecipient = address(0x2);
    address public buyer1 = address(0x3);
    address public buyer2 = address(0x4);

    uint256 public constant PRICE = 0.01 ether; // 0.01 ETH per token
    uint256 public constant ALLOCATION = 1000 * 10 ** 18; // 1,000 tokens
    uint256 public constant HARD_CAP = 10 ether;
    uint256 public constant WALLET_LIMIT = 2 ether;
    uint256 public constant FEE_BPS = 250; // 2.5%

    uint256 public startTime;
    uint256 public endTime;

    function setUp() public {
        vm.warp(1000); // Ground block.timestamp
        startTime = block.timestamp + 1 days;
        endTime = block.timestamp + 5 days;

        // Deploy token and mint to test contract
        token = new MockToken("Launch Token", "LTK", ALLOCATION);

        TokenLaunchpad.SaleConfig memory config = TokenLaunchpad.SaleConfig({
            token: token,
            price: PRICE,
            totalAllocation: ALLOCATION,
            startTime: startTime,
            endTime: endTime,
            hardCap: HARD_CAP,
            perWalletLimit: WALLET_LIMIT
        });

        launchpad = new TokenLaunchpad(creator, feeRecipient, FEE_BPS, config);

        // Fund launchpad contract with tokens allocated for the sale
        token.transfer(address(launchpad), ALLOCATION);

        // Give buyers some ETH
        vm.deal(buyer1, 10 ether);
        vm.deal(buyer2, 10 ether);
    }

    // --- Main Flows ---

    function test_SuccessfulSaleFlow() public {
        // Warp to active window
        vm.warp(startTime + 1 hours);

        // Buyer 1 purchases tokens
        vm.prank(buyer1);
        launchpad.purchaseTokens{value: 1 ether}();

        assertEq(launchpad.totalRaised(), 1 ether);
        assertEq(launchpad.contributions(buyer1), 1 ether);

        // Warp to post-sale period
        vm.warp(endTime + 1 hours);

        // Creator withdraws proceeds
        uint256 initialCreatorBalance = creator.balance;
        uint256 initialFeeBalance = feeRecipient.balance;

        vm.prank(creator);
        launchpad.withdrawProceeds();

        uint256 expectedFee = (1 ether * FEE_BPS) / 10000;
        uint256 expectedNet = 1 ether - expectedFee;

        assertEq(creator.balance - initialCreatorBalance, expectedNet);
        assertEq(feeRecipient.balance - initialFeeBalance, expectedFee);

        // Buyer claims tokens
        uint256 expectedTokens = (1 ether * 10 ** 18) / PRICE;
        vm.prank(buyer1);
        launchpad.claimTokens();

        assertEq(token.balanceOf(buyer1), expectedTokens);
    }

    // --- Unauthorized & Invalid Flows ---

    function test_Revert_PurchaseOutsideTimeWindow() public {
        // Attempt purchase before start time
        vm.warp(startTime - 1 hours);
        vm.prank(buyer1);
        vm.expectRevert(TokenLaunchpad.SaleNotActive.selector);
        launchpad.purchaseTokens{value: 1 ether}();

        // Attempt purchase after end time
        vm.warp(endTime + 1 hours);
        vm.prank(buyer1);
        vm.expectRevert(TokenLaunchpad.SaleNotActive.selector);
        launchpad.purchaseTokens{value: 1 ether}();
    }

    function test_Revert_UnauthorizedWithdrawal() public {
        vm.warp(endTime + 1 hours);
        
        // Non-creator attempts withdrawal
        vm.prank(buyer1);
        vm.expectRevert(TokenLaunchpad.OnlyCreator.selector);
        launchpad.withdrawProceeds();
    }

    function test_Revert_ClaimBeforeSaleEnds() public {
        vm.warp(startTime + 1 hours);
        vm.prank(buyer1);
        launchpad.purchaseTokens{value: 1 ether}();

        // Attempting to claim while sale is still active
        vm.prank(buyer1);
        vm.expectRevert(TokenLaunchpad.SaleHasNotEnded.selector);
        launchpad.claimTokens();
    }

    // --- Boundary & Enforcement Tests ---

    function test_WalletLimitEnforcement() public {
        vm.warp(startTime + 1 hours);

        // Spend exactly the limit
        vm.prank(buyer1);
        launchpad.purchaseTokens{value: WALLET_LIMIT}();

        // Attempt to exceed limit by 1 wei
        vm.prank(buyer1);
        vm.expectRevert(TokenLaunchpad.WalletLimitExceeded.selector);
        launchpad.purchaseTokens{value: 1}();
    }

    function test_HardCapEnforcement() public {
        vm.warp(startTime + 1 hours);

        // Track allocations via distinct buyers due to per-wallet limits
        uint256 segments = HARD_CAP / WALLET_LIMIT;
        for (uint256 i = 0; i < segments; i++) {
            address temporaryBuyer = address(uint160(0x100 + i));
            vm.deal(temporaryBuyer, WALLET_LIMIT);
            vm.prank(temporaryBuyer);
            launchpad.purchaseTokens{value: WALLET_LIMIT}();
        }

        // Attempting to buy over the hardcap allocation boundary
        address overflowBuyer = address(0x999);
        vm.deal(overflowBuyer, 1 ether);
        vm.prank(overflowBuyer);
        vm.expectRevert(TokenLaunchpad.HardCapExceeded.selector);
        launchpad.purchaseTokens{value: 1 ether}();
    }

    function test_RecoveryOfUnsoldTokens() public {
        vm.warp(startTime + 1 hours);
        vm.prank(buyer1);
        launchpad.purchaseTokens{value: 1 ether}(); // Consumes 100 tokens

        vm.warp(endTime + 1 hours);

        uint256 expectedUnsold = ALLOCATION - ((1 ether * 10 ** 18) / PRICE);
        
        uint256 initialCreatorTokenBalance = token.balanceOf(creator);
        vm.prank(creator);
        launchpad.recoverUnsoldTokens();

        assertEq(token.balanceOf(creator) - initialCreatorTokenBalance, expectedUnsold);
    }

    // --- Fuzz Tests ---

    function testFuzz_PurchaseLimits(uint256 amount) public {
        // Bound fuzzed purchase amounts within the minimum possible unit and wallet boundary cap
        vm.assume(amount > 0 && amount <= WALLET_LIMIT);
        
        vm.warp(startTime + 1 hours);
        vm.prank(buyer2);
        launchpad.purchaseTokens{value: amount}();
        
        assertEq(launchpad.contributions(buyer2), amount);
    }
}
