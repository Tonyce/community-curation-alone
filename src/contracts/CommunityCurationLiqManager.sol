/**
 * @title CommunityCurationLiqManager
 * @dev This contract manages the creation, minting, burning, and graduation of Community Curation tokens.
 * It also handles liquidity management and fee distribution for these tokens.
 */
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "../solady/auth/Ownable.sol";


import {Clones} from "../lib/Clones.sol";
import {SafeERC20} from "../lib/SafeERC20.sol";
import {Math} from "../lib/Math.sol";

import {FixedPoint96} from "../lib/FixedPoint96.sol";

import {IERC20} from "../interfaces/IERC20.sol";
import {IQuoterV2} from "../interfaces/IQuoterV2.sol";
import {IUniswapV3Factory} from "../interfaces/IUniswapV3Factory.sol";
import {IUniswapV3Pool} from "../interfaces/IUniswapV3Pool.sol";
import {INonfungiblePositionManager} from "../interfaces/INonfungiblePositionManager.sol";
import {ISwapRouter02} from "../interfaces/ISwapRouter02.sol";
import {IBondingCurve} from "../interfaces/IBondingCurve.sol";

import {Treasury} from "./Treasury.sol";
import {CommunityCuration} from "./CommunityCuration.sol";
import {Dan} from "./Dan.sol";

contract CommunityCurationLiqManager is Ownable {
    using SafeERC20 for IERC20;
    using Clones for address;

    // Constants
    int24 private constant TICK_SPACING = 60;
    int24 public constant MIN_TICK = -887272;
    int24 public constant MAX_TICK = -MIN_TICK;
    uint24 public constant POOL_FEE = 3_000; // 10_000 = 1% 3_000 = 0.3% 500 = 0.05%
    uint256 private constant X96 = 2 ** 96;
    uint256 public constant BIP = 10_000;
    uint256 public constant DEGENCAST_LIQUIDITY_FEE_BIP = 50; // the fee for add liquidity

    uint256 public constant DEGENCAST_FEE_BIP = 100; // 1%
    uint256 public constant CHANNEL_HOST_FEE_BIP = 200; // 2%
    uint256 public constant CREATOR_FEE_BIP = 300; // 3%
    uint256 public constant CURATOR_FEE_BIP = 400; // 4%

    // State variables
    mapping(address => TokenInfo) public tokens; // token -> tokenInfo
    mapping(string => address) public baseURItoToken;

    address public immutable tokenTemplate;
    address public immutable danTemplate;
    address public immutable protocolFeeAddr;

    INonfungiblePositionManager public immutable UNIV3_POSITION_MANAGER;
    IUniswapV3Factory public immutable uniswapV3Factory;
    IQuoterV2 private immutable quoter;
    ISwapRouter02 private immutable router02;
    IBondingCurve public defaultBondingCurve;
    

    /**
     * @dev Struct to store information about each token
     */
    struct TokenInfo {
        Dan dan;
        CommunityCuration token;
        IERC20 paymentToken;
        IBondingCurve bondingCurve;
        Treasury treasury;
        address creator;
        uint256 totalLiquidity;
        bool graduated;
    }

    struct CommunityCurationConfig {
        string name;
        string symbol;
        string baseURI;
        uint256 unit;
        uint256 maxTokensPerIdPerUser;
        uint256 proposalStake; // proposal stake
        uint256 proposalPeriod; // proposal period duration
        uint256 deadlineDuration; // minting deadline duration
        IERC20 paymentToken;
        address channelHost;
        address protocolAddr;
    }

    struct MintParams {
        uint256 totalPrice;
        uint256 protocolFee;
        uint256 channelHostFee;
        uint256 creatorFee;
        uint256 curatorFee;
    }

    event CommunityCurationCreated(
        address indexed token,
        address indexed dan,
        address indexed paymentToken,
        string name,
        string symbol
    );
    event LiquidityAdded(
        uint256 tokenId,
        address indexed token0,
        uint256 amount0,
        address indexed token1,
        uint256 amount1,
        uint128 totalLiquidity,
        address pool
    );
    event NFTMinted(
        address indexed token,
        address indexed to,
        uint256 tokenId,
        uint256 amount,
        uint256 totalSupply,
        uint256 totalNftSupply,
        uint256 nftPrice
    );
    event NFTBurned(
        address indexed token,
        address indexed from,
        uint256 tokenId,
        uint256 amount,
        uint256 totalSupply,
        uint256 totalNftSupply,
        uint256 nftPrice
    );

    // Errors
    error CommunityCuration__MaxPaymentExceeded(uint256 price, uint256 maxPayment);
    error CommunityCuration__InvalidTokenId();
    error CommunityCuration__TokenNotExists();
    error CommunityCuration__OnlyCreatorAllowed();
    error CommunityCuration__BaseURIExists(string baseURI);
    error CommunityCuration__ProposalStakeZero();
    error CommunityCuration__HasGraduated();
    error CommunityCuration__HasNotGraduated();
    error CommunityCuration__InsufficientPayment();
    error CommunityCuration__NotReachedGraduationPoint();
    error CommunityCuration__MintAmountIsZero();
    error CommunityCuration__InsufficientLeftForCurrentPriceRange();


    /**
     * @dev Constructor to initialize the contract with necessary addresses and templates
     */
    constructor(
        address _uniswapV3Factory,
        address _nonfungiblePositionManager,
        address _quoter,
        address _router02,
        address _tokenTemplate,
        address _danTemplate,
        IBondingCurve _defaultBondingCurve
    ) {
        _initializeOwner(msg.sender);
        uniswapV3Factory = IUniswapV3Factory(_uniswapV3Factory);
        UNIV3_POSITION_MANAGER = INonfungiblePositionManager(
            _nonfungiblePositionManager
        );
        quoter = IQuoterV2(_quoter);
        router02 = ISwapRouter02(_router02);
        danTemplate = _danTemplate;
        tokenTemplate = _tokenTemplate;
        defaultBondingCurve = _defaultBondingCurve;
        protocolFeeAddr = msg.sender;
    }

    /**
     * @dev Creates a new token with the default bonding curve
     * @param _tokenConfig Configuration parameters for the new token
     * @param _contentZero Initial content for the token
     * @return CommunityCuration The newly created token
     */
    function createTokenDefaultCurve(
        CommunityCurationConfig memory _tokenConfig,
        Dan.ContentZero memory _contentZero
    ) external onlyOwner returns (CommunityCuration) {
        if (baseURItoToken[_tokenConfig.baseURI] != address(0)) {
            revert CommunityCuration__BaseURIExists(_tokenConfig.baseURI);
        }
        if (_tokenConfig.proposalStake == 0) {
            revert CommunityCuration__ProposalStakeZero();
        }

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

        Treasury treasury = new Treasury(
            UNIV3_POSITION_MANAGER,
            address(_tokenConfig.paymentToken),
            address(this)
        );

        tokens[address(newToken)] = TokenInfo({
            dan: newDan,
            token: newToken,
            paymentToken: IERC20(_tokenConfig.paymentToken),
            bondingCurve: defaultBondingCurve,
            treasury: treasury,
            creator: msg.sender,
            totalLiquidity: 0,
            graduated: false
        });

        baseURItoToken[_tokenConfig.baseURI] = address(newToken);
        emit CommunityCurationCreated(
            address(newToken),
            address(newDan),
            address(_tokenConfig.paymentToken),
            _tokenConfig.name,
            _tokenConfig.symbol
        );
        return newToken;
    }

    // Modifiers
    modifier onlyCreator(address _tokenAddress) {
        if (tokens[_tokenAddress].creator != msg.sender) {
            revert CommunityCuration__OnlyCreatorAllowed();
        }
        _;
    }

    /**
     * @dev Retrieves token information for a given token address
     * @param token The address of the token
     * @return TokenInfo struct containing token information
     */
    function getTokenInfo(
        address token
    ) public view returns (TokenInfo memory) {
        return tokens[token];
    }

    /**
     * @dev Calculates fees for a given amount
     * @param amount The amount to calculate fees for
     * @return protocolFee The calculated protocol fee
     * @return channelHostFee The calculated channel host fee
     * @return creatorFee The calculated creator fee
     * @return curatorFee The calculated curator fee
     */
    function calculateFees(uint256 amount) public pure returns (uint256 protocolFee, uint256 channelHostFee, uint256 creatorFee, uint256 curatorFee) {
        protocolFee = (amount * DEGENCAST_FEE_BIP) / BIP;
        channelHostFee = (amount * CHANNEL_HOST_FEE_BIP) / BIP;
        creatorFee = (amount * CREATOR_FEE_BIP) / BIP;
        curatorFee = (amount * CURATOR_FEE_BIP) / BIP;
    }

    /**
     * @dev Distributes fees to various stakeholders
     * @param _tokenAddress The address of the token
     * @param _tokenId The ID of the token
     * @param params Struct containing fee amounts
     */
    function distributeFees(address _tokenAddress, uint256 _tokenId, MintParams memory params) 
        internal {
        TokenInfo storage tokenInfo = tokens[_tokenAddress];
        Dan dan = tokenInfo.dan;
        
        (address creator, address channelHost) = dan.getFeeRecipients(_tokenId);
        
        // Distribute Degencast fee
        tokenInfo.paymentToken.safeTransfer(protocolFeeAddr, params.protocolFee);
        
        // Distribute channel host fee
        tokenInfo.paymentToken.safeTransfer(channelHost, params.channelHostFee);
        
        // Distribute creator fee
        tokenInfo.paymentToken.safeTransfer(creator, params.creatorFee);
        
        // Distribute curator fees
        (address[] memory curators, uint256[] memory curatorFees) = dan.calculateCuratorFees(_tokenId, params.curatorFee);
        uint256 distributedCuratorFee = 0;
        for (uint256 i = 0; i < curators.length; i++) {
            tokenInfo.paymentToken.safeTransfer(curators[i], curatorFees[i]);
            distributedCuratorFee += curatorFees[i];
        }
        
        // If there are more curators than MAX_PAID_CURATORS, the remaining fee goes to the treasury
        if (distributedCuratorFee < params.curatorFee) {
            uint256 remainingCuratorFee = params.curatorFee - distributedCuratorFee;
            tokenInfo.paymentToken.safeTransfer(address(tokenInfo.treasury), remainingCuratorFee);
        }
    }

    /**
     * @dev Mints new NFTs
     * @param _tokenAddress The address of the token
     * @param _tokenId The ID of the token to mint
     * @param _amount The amount of tokens to mint
     * @param _maxPayment The maximum payment allowed
     */
    function mintNFT(
        address _tokenAddress,
        uint256 _tokenId,
        uint256 _amount,
        uint256 _maxPayment
    ) external {
        if (tokens[_tokenAddress].paymentToken == IERC20(address(0))) {
            revert CommunityCuration__TokenNotExists();
        }
        if (tokens[_tokenAddress].graduated) {
            revert CommunityCuration__HasGraduated();
        }
        // tokenId validation
        if (!tokens[_tokenAddress].dan.checkTokenIdValid(_tokenId)) {
            revert CommunityCuration__InvalidTokenId();
        }

        TokenInfo storage tokenInfo = tokens[_tokenAddress];
        uint256 nftTotalSupply = tokenInfo.token.totalSupply() /
            tokenInfo.token.unit();
        if (
            nftTotalSupply + _amount >
            tokenInfo.bondingCurve.getSupplyGraduationPoint()
        ) {
            revert CommunityCuration__InsufficientLeftForCurrentPriceRange();
        }

        MintParams memory params = MintParams({
            totalPrice: 0,
            protocolFee: 0,
            channelHostFee: 0,
            creatorFee: 0,
            curatorFee: 0
        });
        (params.totalPrice, params.protocolFee, 
        params.channelHostFee, params.creatorFee, params.curatorFee) = getMintNFTPriceAndFee(_tokenAddress, _amount);

        if (params.totalPrice > _maxPayment) {
            revert CommunityCuration__MaxPaymentExceeded(params.totalPrice, _maxPayment);
        }

        tokenInfo.totalLiquidity += params.totalPrice;
        tokenInfo.paymentToken.safeTransferFrom(
            msg.sender,
            address(this),
            params.totalPrice+params.protocolFee+params.channelHostFee+params.creatorFee+params.curatorFee
        );

        // Distribute fees
        distributeFees(_tokenAddress, _tokenId, params);
        tokenInfo.token.mint(msg.sender, _tokenId, _amount, "");

        uint256 currTotalSupply = tokenInfo.token.totalSupply();
        uint256 currTotalNFTSupply = tokenInfo.token.totalNFTSupply();
        uint256 currNFTPrice = tokenInfo.bondingCurve.getCurrNFTPrice(currTotalNFTSupply);
        emit NFTMinted(_tokenAddress, msg.sender, _tokenId, _amount, currTotalSupply, currTotalNFTSupply, currNFTPrice);
    }

    /**
     * @dev Burns NFTs
     * @param _tokenAddress The address of the token
     * @param _tokenId The ID of the token to burn
     * @param _amount The amount of tokens to burn
     */
    function burnNFT(
        address _tokenAddress,
        uint256 _tokenId,
        uint256 _amount
    ) external {
        if (tokens[_tokenAddress].paymentToken == IERC20(address(0))) {
            revert CommunityCuration__TokenNotExists();
        }
        if (tokens[_tokenAddress].graduated) {
            revert CommunityCuration__HasGraduated();
        }

        TokenInfo storage tokenInfo = tokens[_tokenAddress];
        MintParams memory params = MintParams({
            totalPrice: 0,
            protocolFee: 0,
            channelHostFee: 0,
            creatorFee: 0,
            curatorFee: 0
        });
        (params.totalPrice, params.protocolFee, 
        params.channelHostFee, params.creatorFee, params.curatorFee) = getBurnNFTPriceAndFee(_tokenAddress, _amount);

        tokenInfo.totalLiquidity -= params.totalPrice;
        tokenInfo.paymentToken.safeTransfer(
            msg.sender,
            params.totalPrice-(params.protocolFee+params.channelHostFee+params.creatorFee+params.curatorFee)
        );

        // Distribute fees
        distributeFees(_tokenAddress, _tokenId, params);
        tokenInfo.token.burnNFT(msg.sender, _tokenId, _amount);

        uint256 currTotalSupply = tokenInfo.token.totalSupply();
        uint256 currTotalNFTSupply = tokenInfo.token.totalNFTSupply();
        uint256 currNFTPrice = tokenInfo.bondingCurve.getCurrNFTPrice(currTotalNFTSupply);
        emit NFTBurned(_tokenAddress, msg.sender, _tokenId, _amount, currTotalSupply, currTotalNFTSupply, currNFTPrice);
    }

    /**
     * @dev Withdraws fees for a graduated token
     * @param _tokenAddress The address of the token
     * @return paymentTokenAmount The amount of payment tokens withdrawn
     * @return schellingTokenAmount The amount of schelling tokens withdrawn
     */
    function withdrawFee(
        address _tokenAddress
    )
        external
        onlyCreator(_tokenAddress)
        returns (uint256 paymentTokenAmount, uint256 schellingTokenAmount)
    {
        TokenInfo storage tokenInfo = tokens[_tokenAddress];
        if (!tokenInfo.graduated) {
            revert CommunityCuration__HasNotGraduated();
        }

        return tokenInfo.treasury.collectAndWithdrawFees(msg.sender);
    }

    function getMintNFTPriceAfterFee(
        address _token,
        uint256 _amount
    ) external view returns (uint256) {
        (
            uint256 nftPrice,
            uint256 protocolFee,
            uint256 channelHostFee,
            uint256 creatorFee,
            uint256 totalCuratorFee
        ) = getMintNFTPriceAndFee(_token, _amount);
        return nftPrice + (protocolFee + channelHostFee + creatorFee + totalCuratorFee);
    }

    function getBurnNFTPriceAfterFee(
        address _token,
        uint256 _amount
    ) external view returns (uint256) {
        (
            uint256 nftPrice,
            uint256 protocolFee,
            uint256 channelHostFee,
            uint256 creatorFee,
            uint256 totalCuratorFee
        ) = getBurnNFTPriceAndFee(_token, _amount);
        return nftPrice - (protocolFee + channelHostFee + creatorFee + totalCuratorFee);
    }

    function getMintNFTPriceAndFee(
        address _tokenAddress,
        uint256 _amount
    ) public view 
        returns (uint256 nftPrice, uint256 protocolFee, uint256 channelHostFee, uint256 creatorFee, uint256 totalCuratorFee) {
        TokenInfo storage tokenInfo = tokens[_tokenAddress];
        uint256 nftTotalSupply = tokenInfo.token.totalSupply() /
            tokenInfo.token.unit();
        nftPrice = tokenInfo.bondingCurve.getNextMintNFTPrice(
            nftTotalSupply,
            _amount
        );
        (protocolFee, channelHostFee, creatorFee, totalCuratorFee) = calculateFees(nftPrice);
    }

    function getBurnNFTPriceAndFee(
        address _tokenAddress,
        uint256 _amount
    )
        public
        view
        returns (uint256 nftPrice, uint256 protocolFee, uint256 channelHostFee, uint256 creatorFee, uint256 totalCuratorFee)
    {
        TokenInfo storage tokenInfo = tokens[_tokenAddress];
        uint256 nftTotalSupply = tokenInfo.token.totalSupply() /
            tokenInfo.token.unit();
        nftPrice = tokenInfo.bondingCurve.getPrevMintNFTPrice(
            nftTotalSupply,
            _amount
        );
        (protocolFee, channelHostFee, creatorFee, totalCuratorFee) = calculateFees(nftPrice);
    }

    /**
     * @dev Graduates a token, creating a Uniswap V3 pool and adding initial liquidity
     * @param _tokenAddress The address of the token to graduate
     * @return tokenId The ID of the newly created Uniswap V3 position
     * @return liquidity The amount of liquidity added to the pool
     * @return amount0 The amount of token0 added to the pool
     * @return amount1 The amount of token1 added to the pool
     */
    function graduate(
        address _tokenAddress
    )
        external
        onlyCreator(_tokenAddress)
        returns (
            uint256 tokenId,
            uint128 liquidity,
            uint256 amount0,
            uint256 amount1
        )
    {
        if (tokens[_tokenAddress].token.totalNFTSupply() < IBondingCurve(tokens[_tokenAddress].bondingCurve).getSupplyGraduationPoint() ) {
            revert CommunityCuration__NotReachedGraduationPoint();
        }
    
        tokens[_tokenAddress].token.unpause();
        tokens[_tokenAddress].graduated = true;

        address token0;
        address token1;
        address pool;
        uint256 amount0Desired;
        uint256 amount1Desired;

        {
            TokenInfo storage tokenInfo = tokens[_tokenAddress];
            CommunityCuration token = tokens[_tokenAddress].token;

            // admin fee for liquidity
            uint256 adminLpFee = (tokenInfo.totalLiquidity *
                DEGENCAST_LIQUIDITY_FEE_BIP) / BIP;
            tokenInfo.paymentToken.safeTransfer(owner(), adminLpFee);
            uint256 totalLiquidityWithoutFee = tokenInfo.totalLiquidity -
                adminLpFee;

            uint256 currNFTPrice = tokenInfo.bondingCurve.getCurrNFTPrice(
                tokenInfo.token.totalSupply() / tokenInfo.token.unit()
            );
            uint256 tokenAmountForLiquidity = (totalLiquidityWithoutFee *
                tokenInfo.token.unit()) / currNFTPrice;

            token.mint(address(this), tokenAmountForLiquidity);
            token.approve(
                address(UNIV3_POSITION_MANAGER),
                tokenAmountForLiquidity
            );
            tokenInfo.paymentToken.approve(
                address(UNIV3_POSITION_MANAGER),
                totalLiquidityWithoutFee
            );

            token0 = address(token);
            token1 = address(tokenInfo.paymentToken);
            bool tokenIsToken0 = token0 < token1;
            if (!tokenIsToken0) {
                address temp = address(token0);
                token0 = token1;
                token1 = temp;
            }

            pool = uniswapV3Factory.createPool(
                address(token0),
                address(token1),
                POOL_FEE
            );

            amount0Desired = tokenIsToken0
                ? tokenAmountForLiquidity
                : totalLiquidityWithoutFee;
            amount1Desired = tokenIsToken0
                ? totalLiquidityWithoutFee
                : tokenAmountForLiquidity;

            uint160 sqrtPriceX96 = uint160(
                (Math.sqrt((amount1Desired * 1e18) / amount0Desired) * X96) /
                    1e9
            );
            IUniswapV3Pool(pool).initialize(sqrtPriceX96);
        }

        INonfungiblePositionManager.MintParams
            memory params = INonfungiblePositionManager.MintParams({
                token0: token0,
                token1: token1,
                fee: POOL_FEE,
                tickLower: (MIN_TICK / TICK_SPACING) * TICK_SPACING,
                tickUpper: (MAX_TICK / TICK_SPACING) * TICK_SPACING,
                amount0Desired: amount0Desired,
                amount1Desired: amount1Desired,
                amount0Min: 0,
                amount1Min: 0,
                recipient: address(tokens[_tokenAddress].treasury),
                deadline: block.timestamp
            });

        (tokenId, liquidity, amount0, amount1) = UNIV3_POSITION_MANAGER.mint(
            params
        );

        tokens[_tokenAddress].treasury.setTokenId(tokenId);
        tokens[_tokenAddress].token.transferOwnership(address(0x01));

        emit LiquidityAdded(
            tokenId,
            token0,
            amount0,
            token1,
            amount1,
            liquidity,
            pool
        );
    }

    /**
     * @dev Gets the mint price and fees for a graduated token using Uniswap V3
     * @param _token The address of the token
     * @param _amount The amount of tokens to mint
     * @return nftPrice The price of the NFT
     * @return protocolFee The protocol fee
     * @return channelHostFee The channel host fee
     * @return creatorFee The creator fee
     * @return totalCuratorFee The total curator fee
     */
    function getMintNFTPriceAndFeeFromUniV3(
        address _token, uint256 _amount
    ) internal view returns (
        uint256 nftPrice, uint256 protocolFee, uint256 channelHostFee, uint256 creatorFee, uint256 totalCuratorFee
    ) {
        TokenInfo storage tokenInfo = tokens[_token];
        if (!tokenInfo.graduated) {
            revert CommunityCuration__HasNotGraduated();
        }
        if (_amount == 0) {
            revert CommunityCuration__MintAmountIsZero();
        }

        {
            uint256 tokenAmount = tokenInfo.token.unit() * _amount;
            address token0 = address(_token);
            address token1 = address(tokenInfo.paymentToken);
            address pool = uniswapV3Factory.getPool(token0, token1, POOL_FEE);
            (uint160 sqrtPriceX96, , , , , ,) = IUniswapV3Pool(pool).slot0();
            uint256 price1 = (uint256(sqrtPriceX96 * 1e9) / X96) ** 2;
            uint256 price0 = 1e18;
            
            bool tokenIsToken0 = token0 < token1;
            if (tokenIsToken0) {
                nftPrice = tokenAmount * price1 / price0;
            } else {
                nftPrice = tokenAmount * price0 / price1 ;
            }
        }
        (protocolFee, channelHostFee, creatorFee, totalCuratorFee) = calculateFees(nftPrice);
    }

    /**
     * @dev Gets the mint price for a graduated token using Uniswap V3
     * @param _token The address of the token
     * @param _amount The amount of tokens to mint
     * @return The total price including fees
     */
    function getMintNFTPriceFromUniV3(address _token, uint256 _amount) public view returns (uint256) {
        (
            uint256 nftPrice,
            uint256 protocolFee,
            uint256 channelHostFee,
            uint256 creatorFee,
            uint256 totalCuratorFee
        ) = getMintNFTPriceAndFeeFromUniV3(_token, _amount);
        return nftPrice + (protocolFee + channelHostFee + creatorFee + totalCuratorFee);
    }

    /**
     * @dev Mints NFTs for a graduated token using Uniswap V3 for price discovery
     * @param _token The address of the token
     * @param _tokenId The ID of the token to mint
     * @param _amount The amount of tokens to mint
     * @param _paymentAmount The amount of payment token provided
     */
    function mintNFTFromUniV3(address _token, uint256 _tokenId, uint256 _amount, uint256 _paymentAmount) public returns (uint256) {
        TokenInfo storage tokenInfo = tokens[_token];
        if (!tokenInfo.graduated) {
            revert CommunityCuration__HasNotGraduated();
        }

        MintParams memory priceParams = MintParams({
            totalPrice: 0,
            protocolFee: 0,
            channelHostFee: 0,
            creatorFee: 0,
            curatorFee: 0
        });
        (
            priceParams.totalPrice, priceParams.protocolFee, priceParams.channelHostFee, priceParams.creatorFee, priceParams.curatorFee
        ) = getMintNFTPriceAndFeeFromUniV3(_token, _amount);

        if (_paymentAmount < (priceParams.totalPrice + priceParams.protocolFee + priceParams.channelHostFee + priceParams.creatorFee + priceParams.curatorFee)) {
            revert CommunityCuration__InsufficientPayment();
        }

        tokenInfo.paymentToken.safeTransferFrom(
            msg.sender,
            address(this),
            _paymentAmount
        );
        distributeFees(_token, _tokenId, priceParams);

        uint256 tokenAmountNeeded = tokenInfo.token.unit() * _amount;
        uint256 _paymentLeft = _paymentAmount - (priceParams.protocolFee + priceParams.channelHostFee + priceParams.creatorFee + priceParams.curatorFee);
        tokenInfo.paymentToken.approve(address(router02), _paymentLeft);

        ISwapRouter02.ExactInputSingleParams memory swapParams = ISwapRouter02
            .ExactInputSingleParams({
                tokenIn: address(tokenInfo.paymentToken),
                tokenOut: _token,
                fee: POOL_FEE,
                recipient: msg.sender,   
                amountIn: _paymentLeft,
                amountOutMinimum: tokenAmountNeeded,
                sqrtPriceLimitX96: 0
            });
        
        uint256 tokenAmountOut = router02.exactInputSingle(swapParams);
        tokenInfo.token.mintFromBlank(msg.sender, msg.sender, _tokenId, _amount, "");
        uint256 currTotalSupply = tokenInfo.token.totalSupply();
        uint256 currTotalNFTSupply = tokenInfo.token.totalNFTSupply();
        uint256 currNFTPrice = priceParams.totalPrice / _amount;
        emit NFTMinted(_token, msg.sender, _tokenId, _amount, currTotalSupply, currTotalNFTSupply, currNFTPrice);
        return tokenAmountOut;
    }

    function updateMaxTokensPerIdPerUser(address _token, uint256 _maxTokensPerIdPerUser) external onlyOwner {
        tokens[_token].token.setMaxTokensPerIdPerUser(_maxTokensPerIdPerUser);
    }
}
