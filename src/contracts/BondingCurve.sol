// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IBondingCurve} from "../interfaces/IBondingCurve.sol";

/// @title BondingCurve
/// @notice Implements a bonding curve for NFT pricing
/// @dev This contract calculates NFT prices based on supply and a configurable curve
contract BondingCurve is IBondingCurve {
    /// `basePrice`: The initial price of the SchellingToken.
    uint256 public basePrice;
    /// `supplyGraduationPoint`: The point at which the token supply has fully increased, causing the price to stabilize.
    uint256 public supplyGraduationPoint;
    /// `priceCurveConfig`: The configuration for the price curve of the token.
    uint256 public priceCurveConfig;

    /// @notice Initializes the BondingCurve contract
    /// @param _basePrice The initial price of the SchellingToken
    /// @param _supplyGraduationPoint The point at which the token supply has fully increased
    /// @param _priceCurveConfig The configuration for the price curve of the token
    constructor(
        uint256 _basePrice,
        uint256 _supplyGraduationPoint,
        uint256 _priceCurveConfig
    ) {
        basePrice = _basePrice;
        supplyGraduationPoint = _supplyGraduationPoint;
        priceCurveConfig = _priceCurveConfig;
    }

    /// @notice Returns the base price of the token
    /// @return The base price
    function getBasePrice() public view override returns (uint256) {
        return basePrice;
    }

    /// @notice Returns the supply graduation point
    /// @return The supply graduation point
    function getSupplyGraduationPoint() public view override returns (uint256) {
        return supplyGraduationPoint;
    }

    /// @notice Calculates the current NFT price based on the current supply
    /// @param _currNFTSupply The current NFT supply
    /// @return nftPrice The current NFT price
    function getCurrNFTPrice(
        uint256 _currNFTSupply
    ) public view returns (uint256 nftPrice) {
        nftPrice = getPrevMintNFTPrice(_currNFTSupply, 1);
    }

    /// @notice Calculates the NFT price for the next mint
    /// @param _currNFTSuppy The current NFT supply
    /// @param _amount The amount of NFTs to mint
    /// @return nftPrice The price for the next NFT mint
    function getNextMintNFTPrice(
        uint256 _currNFTSuppy,
        uint256 _amount
    ) public view returns (uint256 nftPrice) {
        nftPrice = getPrice(_currNFTSuppy, _amount);
    }

    /// @notice Calculates the NFT price for the previous mint
    /// @param _currNFTSupply The current NFT supply
    /// @param _amount The amount of NFTs that were minted
    /// @return nftPrice The price for the previous NFT mint
    function getPrevMintNFTPrice(
        uint256 _currNFTSupply,
        uint256 _amount
    ) public view returns (uint256 nftPrice) {
        if (_currNFTSupply == 0) {
            nftPrice = basePrice;
        } else {
            nftPrice = getPrice(_currNFTSupply - _amount, _amount);
        }
    }

    /// @notice Calculates the price based on supply and amount
    /// @dev Uses a quadratic summation formula to calculate the price
    /// @param supply The current supply
    /// @param amount The amount of tokens to calculate for
    /// @return The calculated price
    function getPrice(
        uint256 supply,
        uint256 amount
    ) public view returns (uint256) {
        uint256 sum1 = supply == 0
            ? 0
            : ((supply - 1) * (supply) * (2 * (supply - 1) + 1)) / 6;

        uint256 sum2 = supply == 0 && amount == 1
            ? 0
            : ((supply + amount - 1) *
                (supply + amount) *
                (2 * (supply + amount - 1) + 1)) / 6;

        uint256 summation = sum2 - sum1;
        uint256 price = (summation * 1 ether) /
            priceCurveConfig +
            (basePrice * amount);
        return price;
    }
}