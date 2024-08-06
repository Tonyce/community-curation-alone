// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "../solady/auth/Ownable.sol";
import {Initializable} from "../solady/utils/Initializable.sol";

import {DN420} from "../dn420/DN420.sol";

import {IDan} from "../interfaces/IDan.sol";

/// @title CommunityCuration
/// @notice A contract for community-curated token minting and management
/// @dev Inherits from DN420 and implements additional functionality for token curation
contract CommunityCuration is DN420, Ownable, Initializable {
    IDan public dan;
    address public factory;
    uint256 public maxTokensPerIdPerUser; // Default max tokens per ID per user
    
    bool private _paused;

    error InvalidTokenId();
    error MintingDeadlinePassed();
    error ExceedsMaxTokensPerIdPerUser();
    error OnlyFactoryAllowed();
    error HasPaused();

    /// @notice Ensures the function is called before the token's minting deadline
    /// @param tokenId The ID of the token to check
    modifier beforeDeadline(uint256 tokenId) {
        if (block.timestamp > dan.getTokenDeadline(tokenId)) revert MintingDeadlinePassed();
        _;
    }

    /// @notice Ensures the token ID is valid
    /// @param tokenId The ID of the token to check
    modifier validTokenId(uint256 tokenId) {
        if (!dan.checkTokenIdValid(tokenId)) revert InvalidTokenId();
        _;
    }

    /// @notice Restricts function access to the factory contract
    modifier onlyFactory() {
        if (msg.sender != factory) revert OnlyFactoryAllowed();
        _;
    }

    constructor() DN420("DN420", "DN420", "", 18, 10 ** 5) {}

    /// @notice Initializes the CommunityCuration contract
    /// @param dan_ Address of the Dan contract
    /// @param factory_ Address of the factory contract
    /// @param name_ Name of the token
    /// @param symbol_ Symbol of the token
    /// @param baseURI_ Base URI for token metadata
    /// @param decimals_ Number of decimals for token amounts
    /// @param tokenUnit_ The base unit for token amounts
    /// @param maxTokensPerIdPerUser_ Maximum number of tokens per ID per user
    function initialize(
        address dan_,
        address factory_,
        string calldata name_,
        string calldata symbol_,
        string calldata baseURI_,
        uint8 decimals_,
        uint256 tokenUnit_,
        uint256 maxTokensPerIdPerUser_
    ) public payable initializer {
        _initializeOwner(msg.sender);
        dan = IDan(dan_);
        factory = factory_;
        name = name_;
        symbol = symbol_;
        baseURI = baseURI_;
        decimals = decimals_;
        tokenUnit = tokenUnit_;
        maxTokensPerIdPerUser = maxTokensPerIdPerUser_;

        maxTokenId = 1;
        _paused = true;
    }

    /// @notice Transfers tokens to another address
    /// @dev Overrides DN420 transfer function to include pause check
    /// @param to The recipient address
    /// @param amount The amount of tokens to transfer
    /// @return bool indicating whether the transfer was successful
    function transfer(address to, uint256 amount) public override(DN420) returns (bool) {
        if (_paused) revert HasPaused();
        return DN420.transfer(to, amount);
    }

    /// @notice Transfers tokens from one address to another
    /// @dev Overrides DN420 transferFrom function to include pause check
    /// @param from The sender address
    /// @param to The recipient address
    /// @param amount The amount of tokens to transfer
    /// @return bool indicating whether the transfer was successful
    function transferFrom(address from, address to, uint256 amount) public override(DN420) returns (bool) {
        if (_paused) revert HasPaused();
        return super.transferFrom(from, to, amount);
    }

    /// @notice Pauses all token transfers
    /// @dev Can only be called by the contract owner
    function pause() public onlyOwner {
        _paused = true;
    }
    function unpause() public onlyOwner {
        _paused = false;
    }

    /// @notice Mints new tokens
    /// @dev Can only be called by the contract owner
    /// @param to The recipient address
    /// @param amount The amount of tokens to mint
    function mint(address to, uint256 amount) public onlyOwner {
        _mint(to, amount);
    }

    /// @notice Mints new tokens for a specific token ID
    /// @dev Can only be called by the contract owner
    /// @param to The recipient address
    /// @param tokenId The ID of the token to mint
    /// @param amount The amount of tokens to mint
    /// @param data Additional data to pass to the mint function
    function mint(
        address to, uint256 tokenId, uint256 amount, bytes memory data
    ) public onlyOwner validTokenId(tokenId) beforeDeadline(tokenId) {
        if (balanceOf(to, tokenId) + amount > maxTokensPerIdPerUser) revert ExceedsMaxTokensPerIdPerUser();
        _mint(to, tokenId, amount, data);
    }

    /// @notice Mints multiple token IDs in a single transaction
    /// @dev Can only be called by the contract owner
    /// @param to The recipient address
    /// @param tokenIds An array of token IDs to mint
    /// @param amounts An array of amounts to mint for each token ID
    /// @param data Additional data to pass to the mint function
    function batchMint(
        address to, uint256[] memory tokenIds, uint256[] memory amounts, bytes memory data
    ) public onlyOwner {
        for (uint256 i = 0; i < tokenIds.length; i++) {
            if (!dan.checkTokenIdValid(tokenIds[i])) revert InvalidTokenId();
            if (block.timestamp > dan.getTokenDeadline(tokenIds[i])) revert MintingDeadlinePassed();
            if (balanceOf(to, tokenIds[i]) + amounts[i] > maxTokensPerIdPerUser) revert ExceedsMaxTokensPerIdPerUser();
        }
        _batchMint(to, tokenIds, amounts, data);
    }

    /// @notice Burns NFTs from a specific address
    /// @dev Can only be called by the contract owner
    /// @param from The address to burn tokens from
    /// @param tokenId The ID of the token to burn
    /// @param amount The amount of tokens to burn
    function burnNFT(address from, uint256 tokenId, uint256 amount) public validTokenId(tokenId) onlyOwner {
        _burn(from, tokenId, amount);
    }

    /// @notice Returns the URI for a given token ID
    /// @param tokenId The ID of the token to query
    /// @return string The URI for the given token ID
    function uri(uint256 tokenId) public view override(DN420) returns (string memory) {
        return dan.getTokenURI(tokenId);
    }

    /// @notice Mints tokens from a blank state
    /// @dev Can only be called by the factory contract
    /// @param from The address to mint from (usually address(0))
    /// @param to The recipient address
    /// @param tokenId The ID of the token to mint
    /// @param amount The amount of tokens to mint
    /// @param data Additional data to pass to the mint function
    function mintFromBlank(
        address from,
        address to,
        uint256 tokenId,
        uint256 amount,
        bytes memory data
    ) public validTokenId(tokenId) beforeDeadline(tokenId) onlyFactory {
        if (balanceOf(to, tokenId) + amount > maxTokensPerIdPerUser) revert ExceedsMaxTokensPerIdPerUser();
        _mintFromBlank(from, to, tokenId, amount, data);
    }

    /// @notice Sets the maximum number of tokens per ID per user
    /// @dev Can only be called by factory contract
    /// @param _maxTokensPerIdPerUser The new maximum number of tokens per ID per user
    function setMaxTokensPerIdPerUser(uint256 _maxTokensPerIdPerUser) public onlyFactory {
        maxTokensPerIdPerUser = _maxTokensPerIdPerUser;
    }

    /// @notice Returns the address of the Dan contract
    /// @return address The address of the Dan contract
    function getDanAddress() public view returns (address) {
        return address(dan);
    }
}