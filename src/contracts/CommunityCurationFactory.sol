/**
 * @title CommunityCurationFactory
 * @dev This contract is responsible for creating and managing CommunityCuration contracts.
 * It extends CommunityCurationLiqManager to handle liquidity management.
 */
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "../interfaces/IERC20.sol";
import {Clones} from "../lib/Clones.sol";

import {IBondingCurve} from "../interfaces/IBondingCurve.sol";
import {CommunityCurationLiqManager} from "./CommunityCurationLiqManager.sol";
import {Treasury} from "./Treasury.sol";
import {CommunityCuration} from "./CommunityCuration.sol";
import {Dan} from "./Dan.sol";

contract CommunityCurationFactory is CommunityCurationLiqManager {
    using Clones for address;

    /**
     * @dev Constructor for CommunityCurationFactory
     * @param _uniswapV3Factory Address of the Uniswap V3 Factory
     * @param _nonfungiblePositionManager Address of the Uniswap V3 Non-fungible Position Manager
     * @param _quoter Address of the Uniswap V3 Quoter
     * @param _router02 Address of the Uniswap V2 Router02
     * @param _tokenTemplate Address of the CommunityCuration template contract
     * @param _danTemplate Address of the Dan template contract
     * @param _defaultBondingCurve Address of the default bonding curve contract
     */
    constructor(
        address _uniswapV3Factory,
        address _nonfungiblePositionManager,
        address _quoter,
        address _router02,
        address _tokenTemplate,
        address _danTemplate,
        IBondingCurve _defaultBondingCurve
    )
        CommunityCurationLiqManager(
            _uniswapV3Factory,
            _nonfungiblePositionManager,
            _quoter,
            _router02,
            _tokenTemplate,
            _danTemplate,
            _defaultBondingCurve
        )
    {}

    /**
     * @dev Creates a new CommunityCuration token with associated Dan and Treasury contracts
     * @param _tokenConfig Configuration parameters for the new token
     * @param _contentZero Initial content for the Dan contract
     * @param _bondingCurve Address of the bonding curve contract to use
     * @return CommunityCuration The newly created CommunityCuration contract
     */
    function createToken(
        CommunityCurationConfig memory _tokenConfig,
        Dan.ContentZero memory _contentZero,
        IBondingCurve _bondingCurve
    ) external onlyOwner returns (CommunityCuration) {
        if (baseURItoToken[_tokenConfig.baseURI] != address(0)) {
            revert CommunityCuration__BaseURIExists(_tokenConfig.baseURI);
        }

        if (_tokenConfig.proposalStake == 0) {
            revert CommunityCuration__ProposalStakeZero();
        }

        // Create and initialize Dan contract
        Dan newDan = Dan(payable(danTemplate.clone()));
        newDan.initialize(
            _tokenConfig.paymentToken,
            _tokenConfig.proposalStake * 10 ** 18,
            _tokenConfig.proposalPeriod,
            _tokenConfig.deadlineDuration,
            _contentZero,
            _tokenConfig.channelHost,
            _tokenConfig.protocolAddr
        );

        // Create and initialize CommunityCuration contract
        CommunityCuration newToken = CommunityCuration(payable(tokenTemplate.clone()));
        newToken.initialize(
            address(newDan),
            address(this),
            _tokenConfig.name,
            _tokenConfig.symbol,
            _tokenConfig.baseURI,
            18,
            _tokenConfig.unit,
            _tokenConfig.maxTokensPerIdPerUser
        );

        // Create Treasury contract
        Treasury treasury = new Treasury(
            UNIV3_POSITION_MANAGER,
            address(_tokenConfig.paymentToken),
            address(this)
        );

        // Store token information
        tokens[address(newToken)] = TokenInfo({
            dan: newDan,
            token: newToken,
            paymentToken: IERC20(_tokenConfig.paymentToken),
            bondingCurve: _bondingCurve,
            treasury: treasury,
            creator: msg.sender,
            totalLiquidity: 0,
            graduated: false
        });

        baseURItoToken[_tokenConfig.baseURI] = address(newToken);
        
        // Emit event for token creation
        emit CommunityCurationCreated(
            address(newToken),
            address(newDan),
            address(_tokenConfig.paymentToken),
            _tokenConfig.name,
            _tokenConfig.symbol
        );
        
        return newToken;
    }
}