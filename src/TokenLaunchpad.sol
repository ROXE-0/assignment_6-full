// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract TokenLaunchpad is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // --- Structs ---
    struct SaleConfig {
        IERC20 token;
        uint256 price;           // Price in wei per 1 whole token (10^18 units)
        uint256 totalAllocation; // Total tokens available for sale
        uint256 startTime;
        uint256 endTime;
        uint256 hardCap;         // Max native currency (ETH) to raise
        uint256 perWalletLimit;  // Max native currency (ETH) a single wallet can contribute
    }

    // --- State Variables ---
    address public immutable creator;
    address public immutable platformFeeRecipient;
    uint256 public immutable platformFeeBps; // In basis points (e.g., 250 = 2.5%)

    SaleConfig public config;
    uint256 public totalRaised;
    uint256 public totalTokensSold;
    bool public fundsWithdrawn;
    bool public unsoldTokensRecovered;

    mapping(address => uint256) public contributions; // Tracks ETH contributed per wallet
    mapping(address => bool) public hasClaimed;

    // --- Events ---
    event SaleConfigured(SaleConfig config);
    event TokensPurchased(address indexed buyer, uint256 ethAmount, uint256 tokenAmount);
    event TokensClaimed(address indexed buyer, uint256 tokenAmount);
    event CreatorWithdrawal(address indexed creator, uint256 netAmount, uint256 feeAmount);
    event UnsoldTokensRecovered(address indexed creator, uint256 amount);

    // --- Custom Errors ---
    error OnlyCreator();
    error InvalidTimeBounds();
    error InvalidAllocation();
    error SaleNotActive();
    error SaleHasNotEnded();
    error HardCapExceeded();
    error WalletLimitExceeded();
    error IncorrectPayment();
    error AlreadyClaimed();
    error NoTokensToClaim();
    error AlreadyWithdrawn();
    error AlreadyRecovered();
    error TransferFailed();

    // --- Modifiers ---
    modifier onlyCreator() {
        if (msg.sender != creator) revert OnlyCreator();
        _;
    }

    constructor(
        address _creator,
        address _platformFeeRecipient,
        uint256 _platformFeeBps,
        SaleConfig memory _config
    ) {
        if (_config.startTime >= _config.endTime || _config.startTime < block.timestamp) revert InvalidTimeBounds();
        if (_config.totalAllocation == 0) revert InvalidAllocation();
        
        creator = _creator;
        platformFeeRecipient = _platformFeeRecipient;
        platformFeeBps = _platformFeeBps;
        config = _config;

        emit SaleConfigured(_config);
    }

    // --- External Functions ---

    /**
     * @notice Purchase tokens during the active sale window using native ETH.
     */
    function purchaseTokens() external payable nonReentrant {
        if (block.timestamp < config.startTime || block.timestamp > config.endTime) revert SaleNotActive();
        if (msg.value == 0) revert IncorrectPayment();
        if (totalRaised + msg.value > config.hardCap) revert HardCapExceeded();
        if (contributions[msg.sender] + msg.value > config.perWalletLimit) revert WalletLimitExceeded();

        // Calculate token amount allocation based on price (ETH per token)
        // tokenAmount = (ethAmount * 10^18) / price
        uint256 tokenAmount = (msg.value * 10 ** 18) / config.price;
        if (totalTokensSold + tokenAmount > config.totalAllocation) revert InvalidAllocation();

        contributions[msg.sender] += msg.value;
        totalRaised += msg.value;
        totalTokensSold += tokenAmount;

        emit TokensPurchased(msg.sender, msg.value, tokenAmount);
    }

    /**
     * @notice Allows buyers to claim their purchased ERC-20 tokens after the sale ends.
     */
    function claimTokens() external nonReentrant {
        if (block.timestamp <= config.endTime) revert SaleHasNotEnded();
        if (hasClaimed[msg.sender]) revert AlreadyClaimed();

        uint256 contribution = contributions[msg.sender];
        if (contribution == 0) revert NoTokensToClaim();

        hasClaimed[msg.sender] = true;
        uint256 tokenAmount = (contribution * 10 ** 18) / config.price;

        config.token.safeTransfer(msg.sender, tokenAmount);

        emit TokensClaimed(msg.sender, tokenAmount);
    }

    /**
     * @notice Allows the creator to withdraw raised ETH and transfers platform fees after the sale ends.
     */
    function withdrawProceeds() external onlyCreator nonReentrant {
        if (block.timestamp <= config.endTime) revert SaleHasNotEnded();
        if (fundsWithdrawn) revert AlreadyWithdrawn();

        fundsWithdrawn = true;
        uint256 balance = totalRaised;
        
        uint256 feeAmount = (balance * platformFeeBps) / 10000;
        uint256 netAmount = balance - feeAmount;

        emit CreatorWithdrawal(creator, netAmount, feeAmount);

        if (feeAmount > 0) {
            (bool feeSuccess, ) = platformFeeRecipient.call{value: feeAmount}("");
            if (!feeSuccess) revert TransferFailed();
        }

        (bool creatorSuccess, ) = creator.call{value: netAmount}("");
        if (!creatorSuccess) revert TransferFailed();
    }

    /**
     * @notice Allows the creator to recover any unsold ERC-20 tokens after the sale ends.
     */
    function recoverUnsoldTokens() external onlyCreator nonReentrant {
        if (block.timestamp <= config.endTime) revert SaleHasNotEnded();
        if (unsoldTokensRecovered) revert AlreadyRecovered();

        unsoldTokensRecovered = true;
        uint256 unsoldAmount = config.totalAllocation - totalTokensSold;

        if (unsoldAmount > 0) {
            config.token.safeTransfer(creator, unsoldAmount);
        }

        emit UnsoldTokensRecovered(creator, unsoldAmount);
    }
}
