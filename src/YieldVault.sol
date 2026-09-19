// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

contract YieldVault is ERC20, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using Math for uint256;

    // --- State Variables ---
    IERC20 public immutable asset;
    address public immutable feeRecipient;
    uint256 public immutable performanceFeeBps; // In basis points (e.g., 1000 = 10%)

    uint256 public lastReportedAssets;

    // --- Events ---
    event Deposit(address indexed sender, address indexed owner, uint256 assets, uint256 shares);
    event Withdraw(
        address indexed sender,
        address indexed receiver,
        address indexed owner,
        uint256 assets,
        uint256 shares
    );
    event StrategyReport(uint256 gain, uint256 feeShares);

    // --- Custom Errors ---
    error ZeroShares();
    error ZeroAssets();
    error ExcessiveWithdrawal();
    error InvalidRecipient();

    constructor(
        IERC20 _asset,
        string memory _name,
        string memory _symbol,
        address _feeRecipient,
        uint256 _performanceFeeBps
    ) ERC20(_name, _symbol) {
        if (_feeRecipient == address(0)) revert InvalidRecipient();
        asset = _asset;
        feeRecipient = _feeRecipient;
        performanceFeeBps = _performanceFeeBps;
    }

    // --- Core ERC-4626 Accounting Views ---

    /**
     * @notice Returns the total amount of underlying assets managed by the vault.
     */
    function totalAssets() public view returns (uint256) {
        return asset.balanceOf(address(this));
    }

    function convertToShares(uint256 assets) public view returns (uint256) {
        uint256 supply = totalSupply();
        return (assets == 0 || supply == 0) 
            ? assets 
            : assets.mulDiv(supply, totalAssets(), Math.Rounding.Floor);
    }

    function convertToAssets(uint256 shares) public view returns (uint256) {
        uint256 supply = totalSupply();
        return (supply == 0) 
            ? shares 
            : shares.mulDiv(totalAssets(), supply, Math.Rounding.Floor);
    }

    function previewDeposit(uint256 assets) public view returns (uint256) {
        return convertToShares(assets);
    }

    function previewWithdraw(uint256 assets) public view returns (uint256) {
        uint256 supply = totalSupply();
        return (supply == 0) 
            ? assets 
            : assets.mulDiv(supply, totalAssets(), Math.Rounding.Ceil);
    }

    // --- Core Write Actions ---

    /**
     * @notice Deposit underlying assets to receive vault shares.
     */
    function deposit(uint256 assets, address receiver) external nonReentrant returns (uint256 shares) {
        if (assets == 0) revert ZeroAssets();
        
        shares = previewDeposit(assets);
        if (shares == 0) revert ZeroShares();

        asset.safeTransferFrom(msg.sender, address(this), assets);
        _mint(receiver, shares);

        emit Deposit(msg.sender, receiver, assets, shares);
    }

    /**
     * @notice Withdraw assets by redeeming an exact amount of underlying tokens.
     */
    function withdraw(uint256 assets, address receiver, address owner) external nonReentrant returns (uint256 shares) {
        if (assets > totalAssets()) revert ExcessiveWithdrawal();

        shares = previewWithdraw(assets);
        
        if (msg.sender != owner) {
            _spendAllowance(owner, msg.sender, shares);
        }

        _burn(owner, shares);
        asset.safeTransfer(receiver, assets);

        emit Withdraw(msg.sender, receiver, owner, assets, shares);
    }

    /**
     * @notice External strategy hook to record yield harvest and extract performance fees cleanly.
     */
    function reportYieldGain(uint256 gain) external nonReentrant {
        if (gain == 0) return;

        // Push new yield tokens directly to simulate harvesting operations
        asset.safeTransferFrom(msg.sender, address(this), gain);

        uint256 currentSupply = totalSupply();
        if (currentSupply > 0 && performanceFeeBps > 0) {
            uint256 feeShares = gain.mulDiv(performanceFeeBps, 10000, Math.Rounding.Floor)
                .mulDiv(currentSupply, totalAssets() - gain, Math.Rounding.Floor);

            if (feeShares > 0) {
                _mint(feeRecipient, feeShares);
                emit StrategyReport(gain, feeShares);
            }
        }
    }
}
