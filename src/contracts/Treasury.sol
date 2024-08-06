/**
 * @title Treasury
 * @dev A contract that manages the treasury for a Uniswap V3 liquidity position.
 * It allows the owner to collect and withdraw fees earned from the liquidity position.
 */
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "../solady/auth/Ownable.sol";
import {IERC20} from "../interfaces/IERC20.sol";
import {IERC721Receiver} from "../interfaces/IERC721Receiver.sol";

import {INonfungiblePositionManager} from "../interfaces/INonfungiblePositionManager.sol";

/**
 * @title Treasury
 * @dev Manages the treasury for a Uniswap V3 liquidity position, allowing fee collection and withdrawal.
 */
contract Treasury is IERC721Receiver, Ownable {
    INonfungiblePositionManager public immutable UNIV3_POSITION_MANAGER;
    IERC20 public immutable PAYMENT_TOKEN;
    uint256 public tokenId;

    error InvalidLPPosition();
    error OnlyV3PositionManager();

    /**
     * @dev Constructor to initialize the Treasury contract.
     * @param _positionManager Address of the Uniswap V3 NonFungiblePositionManager contract.
     * @param _paymentToken Address of the token used for payments.
     * @param _owner Address of the contract owner.
     */
    constructor(
        INonfungiblePositionManager _positionManager,
        address _paymentToken,
        address _owner
    ) {
        _initializeOwner(_owner);
        PAYMENT_TOKEN = IERC20(_paymentToken);
        UNIV3_POSITION_MANAGER = _positionManager;
    }

    /**
     * @dev Sets the token ID of the Uniswap V3 position.
     * @param _tokenId The token ID to set.
     */
    function setTokenId(uint256 _tokenId) external onlyOwner {
        tokenId = _tokenId;
    }

    /**
     * @dev Collects and withdraws fees from the Uniswap V3 position.
     * @param _to Address to receive the collected fees.
     * @return paymentTokenAmount Amount of payment tokens collected.
     * @return schellingTokenAmount Amount of Schelling tokens collected.
     */
    function collectAndWithdrawFees(
        address _to
    )
        external
        onlyOwner
        returns (uint256 paymentTokenAmount, uint256 schellingTokenAmount)
    {
        INonfungiblePositionManager.CollectParams
            memory params = INonfungiblePositionManager.CollectParams({
                tokenId: tokenId,
                recipient: address(this),
                amount0Max: type(uint128).max,
                amount1Max: type(uint128).max
            });

        (uint256 amount0, uint256 amount1) = UNIV3_POSITION_MANAGER.collect(
            params
        );

        (, bytes memory res) = address(UNIV3_POSITION_MANAGER).staticcall(
            abi.encodeWithSelector(
                UNIV3_POSITION_MANAGER.positions.selector,
                tokenId
            )
        );
        (, , address token0, address token1) = abi.decode(
            res,
            (uint96, address, address, address)
        );

        IERC20 schellingToken;
        if (token0 == address(PAYMENT_TOKEN)) {
            paymentTokenAmount = amount0;
            schellingTokenAmount = amount1;
            schellingToken = IERC20(token1);
        } else if (token1 == address(PAYMENT_TOKEN)) {
            paymentTokenAmount = amount1;
            schellingTokenAmount = amount0;
            schellingToken = IERC20(token0);
        } else {
            revert InvalidLPPosition();
        }
        PAYMENT_TOKEN.transfer(_to, paymentTokenAmount);
        schellingToken.transfer(_to, schellingTokenAmount);
    }

    function onERC721Received(
        address,
        address,
        uint256 /** tokenId */,
        bytes calldata /** data  */
    ) external view returns (bytes4) {
        if (msg.sender != address(UNIV3_POSITION_MANAGER))
            revert OnlyV3PositionManager();

        return this.onERC721Received.selector;
    }

    /**
     * @dev Allows the contract to receive ETH.
     */
    receive() external payable {}

    /**
     * @dev Returns the version of the contract.
     * @return string The version number as a string.
     */
    function VERSION() external pure returns (string memory) {
        return "1.0.0";
    }
}