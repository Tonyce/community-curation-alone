// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IBondingCurve {
    function getBasePrice() external view returns (uint256);
    function getSupplyGraduationPoint() external view returns (uint256);

    function getNextMintNFTPrice(
        uint256 _currNFTSuppy,
        uint256 _amount
    ) external view returns (uint256 nftPrice);

    function getPrevMintNFTPrice(
        uint256 _currNFTSuppy,
        uint256 _amount
    ) external view returns (uint256 nftPrice);

    function getCurrNFTPrice(
        uint256 _currNFTSupply
    ) external view returns (uint256 nftPrice);

    function getPrice(
        uint256 supply,
        uint256 amount
    ) external view returns (uint256);
}
