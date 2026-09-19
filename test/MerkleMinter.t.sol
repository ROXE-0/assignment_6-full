// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {MerkleMinter} from "../src/MerkleMinter.sol";

contract MerkleMinterTest is Test {
    MerkleMinter public minter;

    address public owner = address(0x1);
    address public alice = address(0x2);
    address public bob = address(0x3);
    address public publicBuyer = address(0x4);

    uint256 public constant MINT_PRICE = 0.05 ether;
    uint256 public constant TOTAL_SUPPLY = 3;
    uint256 public constant PUBLIC_LIMIT = 1;

    bytes32 public root;
    bytes32[] public aliceProof;
    bytes32[] public bobProof;

    function setUp() public {
        vm.warp(1000);

        // Precompute Leaf Hashes manually matching standard OpenZeppelin verification format
        // Leaf = keccak256(bytes.concat(keccak256(abi.encode(account, allowance))))
        bytes32 leafAlice = keccak256(bytes.concat(keccak256(abi.encode(alice, uint256(1))))); 
        bytes32 leafBob = keccak256(bytes.concat(keccak256(abi.encode(bob, uint256(2)))));

        // Core tree building calculation: Ensure standard sorted hashing to replicate library behaviors
        if (leafAlice < leafBob) {
            root = keccak256(bytes.concat(leafAlice, leafBob));
        } else {
            root = keccak256(bytes.concat(leafBob, leafAlice));
        }

        aliceProof.push(leafBob);
        bobProof.push(leafAlice);

        vm.prank(owner);
        minter = new MerkleMinter(
            "Crypto Artifacts",
            "ARTIFACT",
            root,
            MINT_PRICE,
            TOTAL_SUPPLY,
            PUBLIC_LIMIT,
            "https://metadata.com"
        );

        // Fund accounts
        vm.deal(alice, 10 ether);
        vm.deal(bob, 10 ether);
        vm.deal(publicBuyer, 10 ether);
    }

    // --- Phase and Configuration Verification ---

    function test_InitialStateAndMetadata() public view {
        assertEq(uint256(minter.currentPhase()), uint256(MerkleMinter.SalePhase.Closed));
        assertEq(minter.merkleRoot(), root);
    }

    // --- Main Flow: Allowlist Phase ---

    function test_SuccessfulAllowlistMint() public {
        vm.prank(owner);
        minter.setPhase(MerkleMinter.SalePhase.Allowlist);

        vm.prank(alice);
        minter.allowlistMint{value: MINT_PRICE}(1, aliceProof);

        assertEq(minter.balanceOf(alice), 1);
        assertEq(minter.tokenURI(1), "https://metadata.com1.json");
    }

    // --- Main Flow: Public Phase ---

    function test_SuccessfulPublicMint() public {
        vm.prank(owner);
        minter.setPhase(MerkleMinter.SalePhase.Public);

        vm.prank(publicBuyer);
        minter.publicMint{value: MINT_PRICE}();

        assertEq(minter.balanceOf(publicBuyer), 1);
    }

    // --- Unauthorized & Revert Flows ---

    function test_Revert_MintingWhenClosed() public {
        vm.prank(alice);
        vm.expectRevert(MerkleMinter.PhaseNotActive.selector);
        minter.allowlistMint{value: MINT_PRICE}(1, aliceProof);
    }

    function test_Revert_InvalidMerkleProof() public {
        vm.prank(owner);
        minter.setPhase(MerkleMinter.SalePhase.Allowlist);

        // Presenting Bob's allocation claim to Alice's profile verification step
        vm.prank(alice);
        vm.expectRevert(MerkleMinter.InvalidProof.selector);
        minter.allowlistMint{value: MINT_PRICE}(2, aliceProof); 
    }

    function test_Revert_IncorrectPaymentAmount() public {
        vm.prank(owner);
        minter.setPhase(MerkleMinter.SalePhase.Public);

        vm.prank(publicBuyer);
        vm.expectRevert(MerkleMinter.IncorrectPayment.selector);
        minter.publicMint{value: MINT_PRICE - 1 wei}();
    }

    // --- Boundary Enforcement ---

    function test_DuplicateAndExceededClaimsEnforcement() public {
        vm.prank(owner);
        minter.setPhase(MerkleMinter.SalePhase.Allowlist);

        // First allowed mint
        vm.prank(alice);
        minter.allowlistMint{value: MINT_PRICE}(1, aliceProof);

        // Immediate subsequent duplication attempt
        vm.prank(alice);
        vm.expectRevert(MerkleMinter.ExceedsMaxAllowance.selector);
        minter.allowlistMint{value: MINT_PRICE}(1, aliceProof);
    }

    function test_SupplyExhaustionEnforcement() public {
        vm.prank(owner);
        minter.setPhase(MerkleMinter.SalePhase.Public);

        // Exhaust complete capacity allocations (Supply = 3)
        vm.prank(publicBuyer);
        minter.publicMint{value: MINT_PRICE}();

        vm.prank(alice);
        minter.publicMint{value: MINT_PRICE}();

        vm.prank(bob);
        minter.publicMint{value: MINT_PRICE}();

        // 4th buyer triggers hard exhaustion cap bound checks
        address excessiveBuyer = address(0x9);
        vm.deal(excessiveBuyer, 1 ether);
        
        vm.prank(excessiveBuyer);
        vm.expectRevert(MerkleMinter.SupplyExhausted.selector);
        minter.publicMint{value: MINT_PRICE}();
    }

    function test_AdminWithdrawalProceeds() public {
        vm.prank(owner);
        minter.setPhase(MerkleMinter.SalePhase.Public);

        vm.prank(publicBuyer);
        minter.publicMint{value: MINT_PRICE}();

        uint256 balanceBefore = owner.balance;
        
        vm.prank(owner);
        minter.withdraw();

        assertEq(owner.balance, balanceBefore + MINT_PRICE);
    }
}
