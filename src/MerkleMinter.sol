// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

contract MerkleMinter is ERC721, Ownable, Pausable, ReentrancyGuard {
    using Strings for uint256;

    enum SalePhase { Closed, Allowlist, Public }

    // --- Configuration ---
    bytes32 public merkleRoot;
    uint256 public immutable mintPrice;
    uint256 public immutable totalSupply;
    uint256 public immutable publicPerWalletLimit;
    
    SalePhase public currentPhase;
    uint256 public currentTokenId;
    string private _baseTokenURI;

    // --- Mappings ---
    mapping(address => uint256) public allowlistMinted;
    mapping(address => uint256) public publicMinted;

    // --- Events ---
    event PhaseUpdated(SalePhase indexed newPhase);
    event MerkleRootUpdated(bytes32 indexed newRoot);
    event NFTMinted(address indexed buyer, uint256 indexed tokenId, SalePhase phase);
    event ProceedsWithdrawn(address indexed owner, uint256 amount);
    event BaseURIUpdated(string baseURI);

    // --- Custom Errors ---
    error InvalidPhase();
    error PhaseNotActive();
    error SupplyExhausted();
    error IncorrectPayment();
    error ExceedsMaxAllowance();
    error InvalidProof();
    error TransferFailed();

    constructor(
        string memory name,
        string memory symbol,
        bytes32 _merkleRoot,
        uint256 _mintPrice,
        uint256 _totalSupply,
        uint256 _publicPerWalletLimit,
        string memory initialBaseURI
    ) ERC721(name, symbol) Ownable(msg.sender) {
        merkleRoot = _merkleRoot;
        mintPrice = _mintPrice;
        totalSupply = _totalSupply;
        publicPerWalletLimit = _publicPerWalletLimit;
        _baseTokenURI = initialBaseURI;
        currentPhase = SalePhase.Closed;
    }

    // --- Minting Functions ---

    /**
     * @notice Mint during the Allowlist phase using a valid Merkle proof.
     * @param maxAllowance The leaf-bound maximum allocation for this specific wallet.
     * @param proof The cryptographic proof verifying the caller and their limit.
     */
    function allowlistMint(uint256 maxAllowance, bytes32[] calldata proof) external payable whenNotPaused nonReentrant {
        if (currentPhase != SalePhase.Allowlist) revert PhaseNotActive();
        if (msg.value != mintPrice) revert IncorrectPayment();
        if (currentTokenId >= totalSupply) revert SupplyExhausted();
        if (allowlistMinted[msg.sender] >= maxAllowance) revert ExceedsMaxAllowance();

        // Verify leaf: keccak256(abi.encodePacked(wallet, maxAllowance))
        bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(msg.sender, maxAllowance))));
        if (!MerkleProof.verify(proof, merkleRoot, leaf)) revert InvalidProof();

        allowlistMinted[msg.sender]++;
        currentTokenId++;
        
        _safeMint(msg.sender, currentTokenId);
        emit NFTMinted(msg.sender, currentTokenId, SalePhase.Allowlist);
    }

    /**
     * @notice Mint during the open Public phase.
     */
    function publicMint() external payable whenNotPaused nonReentrant {
        if (currentPhase != SalePhase.Public) revert PhaseNotActive();
        if (msg.value != mintPrice) revert IncorrectPayment();
        if (currentTokenId >= totalSupply) revert SupplyExhausted();
        if (publicMinted[msg.sender] >= publicPerWalletLimit) revert ExceedsMaxAllowance();

        publicMinted[msg.sender]++;
        currentTokenId++;

        _safeMint(msg.sender, currentTokenId);
        emit NFTMinted(msg.sender, currentTokenId, SalePhase.Public);
    }

    // --- Admin Functions ---

    function setPhase(SalePhase _phase) external onlyOwner {
        currentPhase = _phase;
        emit PhaseUpdated(_phase);
    }

    function setMerkleRoot(bytes32 _root) external onlyOwner {
        merkleRoot = _root;
        emit MerkleRootUpdated(_root);
    }

    function setBaseURI(string calldata baseURI) external onlyOwner {
        _baseTokenURI = baseURI;
        emit BaseURIUpdated(baseURI);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function withdraw() external onlyOwner nonReentrant {
        uint256 balance = address(this).balance;
        emit ProceedsWithdrawn(msg.sender, balance);
        
        (bool success, ) = msg.sender.call{value: balance}("");
        if (!success) revert TransferFailed();
    }

    // --- Metadata Views ---

    function _baseURI() internal view override returns (string memory) {
        return _baseTokenURI;
    }

    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        _requireOwned(tokenId);
        string memory base = _baseURI();
        return bytes(base).length > 0 ? string(abi.encodePacked(base, tokenId.toString(), ".json")) : "";
    }
}
