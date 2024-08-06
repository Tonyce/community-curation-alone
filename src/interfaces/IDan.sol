// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "./IERC20.sol";

interface IDan {
    struct ContentZero {
        address creator;
        string contentURI;
    }

    function initialize(IERC20 _paymentToken, uint256 _initialStake, uint256 _period, uint256 _deadlineDuration, ContentZero memory _contentZero, address _channelHost, address _protocolAddr) external payable;
    function checkTokenIdValid(uint256 tokenId) external view returns (bool);
    function getTokenURI(uint256 tokenId) external view returns (string memory);
    function getFeeRecipients(uint256 tokenId) external view returns (address _creator, address _channelHost);
    function calculateCuratorFees(uint256 tokenId, uint256 totalCuratorFee) external view returns (address[] memory, uint256[] memory);
    function getTokenDeadline(uint256 tokenId) external view returns (uint256);
}