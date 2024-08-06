// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "../interfaces/IERC20.sol";
import {SafeERC20} from "../lib/SafeERC20.sol";
import {Math} from "../lib/Math.sol";
import {Initializable} from "../solady/utils/Initializable.sol";

import {Counters} from "../lib/Counters.sol";
import {IDan} from "../interfaces/IDan.sol";

/// @title Dan Contract
/// @notice This contract manages content proposals, voting, and minting of tokens
/// @dev Implements the IDan interface and uses OpenZeppelin libraries
contract Dan is IDan, Initializable {
    using SafeERC20 for IERC20;
    using Counters for Counters.Counter;
    Counters.Counter private _tokenId;

    uint256 public period;
    uint256 public initialStake;
    uint256 public deadlineDuration;
    IERC20 public paymentToken;
    address public channelHost;
    address public protocolAddr;

    uint256 public constant BIP = 10_000;
    uint256 public constant MAX_PAID_CURATORS = 10;

    struct Content {
        string uuid;
        string contentHash;
        address creator;
        uint256 createAt;
        string contentURI;
    }
    mapping(string => uint256) public hashToTokenId;
    mapping(string => uint256) public uriToTokenId;
    mapping(uint256 => Content) public tokenIdToContent;
    mapping(string => mapping(uint256 => mapping(address => bool))) public round;
    mapping(string => Proposal) public proposals;
    mapping(string => string) public proposalCurrentKey;
    mapping(string => VoteResult[]) public upVote; // calculate proposeWeight
    mapping(string => VoteResult[]) public downVote; // calculate disputeWeight


    enum ProposalState {
        Proposed,
        Accepted,
        Disputed,
        ReadyToMint,
        Abandoned
    }
    struct Proposal {
        string currentKey;
        string uuid;
        string contentHash;
        string contentURI;
        address contentCreator;
        address[] curators;
        uint256 proposeWeight;
        uint256 disputeWeight;
        uint256 deadline;
        uint256 roundIndex;
        ProposalState state;
        
    }
    struct VoteResult {
        address voter;
        uint256 amount;
    }
    
    struct ProposalConfig {
        string uuid;
        string contentHash;
        address contentCreator;
        string contentURI;
    }

    error HasStaked();
    error InvalidTokenId();
    error InvalidState();
    error InsufficientStake();
    error ProposalNotExists();
    error ProposalAlreadyExists();
    error ProposalIsNotDisputed();
    error ProposalIsNotProposed();
    error ProposalPeriodEnded();
    error ProposalPeriodNotEnded();
    error ProposalHasReadyToMint();
    error ProposalURIExists();
    error UUIDIsEmpty();
    error ContentHashIsEmpty();
    error ContentHashExists();
    error OnlyContentCreatorAllowed();
    error NoCurators();
    error EitherContentHashOrUUID();
    error OnlyOneContentHashOrUUID();

    event ProposalCreated(
        address indexed contentCreator,
        string contentHash,
        address proposer,
        string contentURI,
        ProposalState state,
        uint256 proposeWeight,
        uint256 disputeWeight,
        uint256 deadline,
        uint256 roundIndex,
        uint256 payment,
        uint256 timestamp
    );
    event ProposalProposed(
        string contentHash,
        address proposer,
        string contentURI,
        ProposalState state,
        uint256 proposeWeight,
        uint256 disputeWeight,
        uint256 deadline,
        uint256 roundIndex,
        uint256 payment,
        uint256 timestamp
    );
    event ProposalDisputed(
        string contentHash,
        address proposer,
        string contentURI,
        ProposalState state,
        uint256 proposeWeight,
        uint256 disputeWeight,
        uint256 deadline,
        uint256 roundIndex,
        uint256 payment,
        uint256 timestamp
    );
    event ProposalReadyToMint(
        string contentHash,
        uint256 tokenId,
        uint256 roundIndex,
        uint256 timestamp,
        string contentURI
    );
    event ContentHashUpdated(string indexed uuid, string indexed newContentHash);

    /// @notice Get a proposal by its key
    /// @param key The key of the proposal (either contentHash or uuid)
    /// @return The Proposal struct
    function getProposal(string memory key) public view returns (Proposal memory) {
        string memory currentKey = proposalCurrentKey[key];
        return proposals[currentKey];
    }

    /// @notice Get content information by token ID
    /// @param tokenId The ID of the token
    /// @return The Content struct associated with the token ID
    function getContent(uint256 tokenId)
        public
        view
        returns (Content memory)
    {
        if (!checkTokenIdValid(tokenId)) {
            revert InvalidTokenId();
        }
        return tokenIdToContent[tokenId];
    }

    /// @notice Initialize the contract
    /// @param _paymentToken The ERC20 token used for payments
    /// @param _initialStake The initial stake required for proposals
    /// @param _period The duration of a voting period
    /// @param _deadlineDuration The duration until a proposal deadline
    /// @param _ContentZero The initial content for token ID 0
    /// @param _channelHost The address of the channel host
    /// @param _protocolAddr The address of the protocol
    function initialize(
        IERC20 _paymentToken,
        uint256 _initialStake,
        uint256 _period,
        uint256 _deadlineDuration,
        IDan.ContentZero memory _ContentZero,
        address _channelHost,
        address _protocolAddr
    ) external payable initializer {
        paymentToken = _paymentToken;
        initialStake = _initialStake;
        period = _period;
        deadlineDuration = _deadlineDuration;
        tokenIdToContent[0] = Content({
            uuid: "0x0",
            contentHash: "0x0",
            creator: _ContentZero.creator,
            createAt: block.timestamp,
            contentURI: _ContentZero.contentURI
        });
        channelHost = _channelHost;
        protocolAddr = _protocolAddr;
    }

    /// @notice Calculate the price to propose a content
    /// @param _contentHash The hash of the content
    /// @return The price to propose
    function getProposePrice(
        string memory _contentHash
    ) public view returns (uint256) {
        if (proposals[_contentHash].roundIndex == 0) {
            revert ProposalNotExists();
        }

        if (proposals[_contentHash].roundIndex == 1) {
            return
                (proposals[_contentHash].proposeWeight * 2) ** 2 -
                proposals[_contentHash].disputeWeight;
        }

        if (proposals[_contentHash].state != ProposalState.Disputed) {
            revert ProposalIsNotDisputed();
        }

        return
            (proposals[_contentHash].disputeWeight * 2) ** 2 -
            proposals[_contentHash].proposeWeight;
    }

    /// @notice Calculate the price to dispute a proposal
    /// @param _contentHash The hash of the content
    /// @return The price to dispute
    function getDisputePrice(
        string memory _contentHash
    ) public view returns (uint256) {
        if (proposals[_contentHash].roundIndex == 0) {
            revert ProposalNotExists();
        }

        if (proposals[_contentHash].state != ProposalState.Proposed && 
            proposals[_contentHash].state != ProposalState.Accepted
        ) {
            revert ProposalIsNotProposed();
        }

        return
            (proposals[_contentHash].proposeWeight * 2) ** 2 -
            proposals[_contentHash].disputeWeight;
    }

    /// @notice Create a new proposal
    /// @param _config The configuration for the new proposal
    /// @param _payment The amount of tokens to stake
    function createProposal(
        ProposalConfig memory _config,
        uint256 _payment
    ) external {
        uint256 contentHashLength;
        uint256 uuidLength;
        {
            bytes memory contentHashBytes = bytes(_config.contentHash);
            bytes memory uuidBytes = bytes(_config.uuid);
            
            // Use assembly for efficient length checks
            assembly {
                contentHashLength := mload(contentHashBytes)
                uuidLength := mload(uuidBytes)
            }
        }
        // Efficient mutually exclusive check
        if (contentHashLength != 0 && uuidLength != 0) {
            revert OnlyOneContentHashOrUUID();
        }
        if (contentHashLength == 0 && uuidLength == 0) {
            revert EitherContentHashOrUUID();
        }

        string memory indexKey = contentHashLength != 0 ? _config.contentHash : _config.uuid;

        if (proposals[indexKey].roundIndex != 0) {
            revert ProposalAlreadyExists();
        }
        if (_payment < initialStake) {
            revert InsufficientStake();
        }


        // Directly write to storage to save gas
        Proposal storage newProposal = proposals[indexKey];
        newProposal.currentKey = indexKey;
        newProposal.uuid = _config.uuid;
        newProposal.contentHash = _config.contentHash;
        newProposal.contentCreator = _config.contentCreator;
        newProposal.proposeWeight = calculateWeight(_payment);
        newProposal.contentURI = _config.contentURI;
        newProposal.deadline = block.timestamp + period;
        newProposal.state = ProposalState.Proposed;
        newProposal.roundIndex = 1;

        // Use a single storage write for the first curator
        newProposal.curators.push(msg.sender);

        round[indexKey][1][msg.sender] = true;

        upVote[indexKey].push(VoteResult({voter: msg.sender, amount: _payment}));
        paymentToken.safeTransferFrom(msg.sender, address(this), _payment);

        proposalCurrentKey[indexKey] = indexKey;

        emit ProposalCreated(
            _config.contentCreator,
            indexKey,
            msg.sender,
            newProposal.contentURI,
            newProposal.state,
            newProposal.proposeWeight,
            newProposal.disputeWeight,
            newProposal.deadline,
            newProposal.roundIndex,
            _payment,
            block.timestamp
        );
    }

    /// @notice Update the content hash for a proposal
    /// @param _uuid The UUID of the proposal
    /// @param _contentHash The new content hash
    function updateContentHash(string memory _uuid, string memory _contentHash) external {
        if (bytes(_uuid).length == 0) {
            revert UUIDIsEmpty();
        }
        if (bytes(_contentHash).length == 0) {
            revert ContentHashIsEmpty();
        }
        if (proposals[_uuid].roundIndex == 0) {
            revert ProposalNotExists();
        }
        if (proposals[_contentHash].roundIndex != 0) {
            revert ContentHashExists();
        }
        if (msg.sender != proposals[_uuid].contentCreator) {
            revert OnlyContentCreatorAllowed();
        }

        Proposal storage proposal = proposals[_uuid];
        proposal.contentHash = _contentHash;
        proposal.currentKey = _contentHash;
        proposalCurrentKey[_uuid] = _contentHash;
        proposalCurrentKey[_contentHash] = _contentHash;

        emit ContentHashUpdated(_uuid, _contentHash);
    }

    /// @notice Dispute an existing proposal
    /// @param _contentHash The hash of the content to dispute
    /// @param _payment The amount of tokens to stake
    function disputeProposal(
        string memory _contentHash,
        uint256 _payment
    ) external {
        Proposal storage proposal = proposals[_contentHash];
        uint256 currRound = proposal.roundIndex;

        if (proposal.state != ProposalState.Proposed && 
            proposal.state != ProposalState.Accepted) 
        {
            revert ProposalIsNotDisputed();
        }
        if (block.timestamp > proposal.deadline) {
            revert ProposalPeriodEnded();
        }
        if (_payment < initialStake) {
            revert InsufficientStake();
        }
        if (round[_contentHash][currRound][msg.sender] == true) {
            revert HasStaked();
        }

        round[_contentHash][currRound][msg.sender] = true;

        downVote[_contentHash].push(
            VoteResult({voter: msg.sender, amount: _payment})
        );
        paymentToken.safeTransferFrom(msg.sender, address(this), _payment);

        proposal.disputeWeight = proposal.disputeWeight + calculateWeight(_payment);

        if (currRound == 1 && downVote[_contentHash].length == 1) {
            proposal.deadline = block.timestamp + period; 
        }

        if (proposal.disputeWeight >= proposal.proposeWeight * 2) {
            if (proposal.state != ProposalState.Disputed) {
                proposal.deadline = block.timestamp + period;
            }
            proposal.state = ProposalState.Disputed;
            proposal.roundIndex += 1;
        }

        emit ProposalDisputed(
            _contentHash,
            msg.sender,
            proposal.contentURI,
            proposal.state,
            proposal.proposeWeight,
            proposal.disputeWeight,
            proposal.deadline,
            proposal.roundIndex,
            _payment,
            block.timestamp
        );
    }

    /// @notice Support an existing proposal
    /// @param _contentHash The hash of the content to support
    /// @param _payment The amount of tokens to stake
    function proposeProposal(
        string memory _contentHash,
        uint256 _payment
    ) external {
        Proposal storage proposal = proposals[_contentHash];
        uint256 currRound = proposal.roundIndex;

        if (currRound > 1 && proposal.state != ProposalState.Disputed) {
            revert ProposalIsNotProposed();
        }
        if (block.timestamp > proposal.deadline) {
            revert ProposalPeriodEnded();
        }
        if (_payment < initialStake) {
            revert InsufficientStake();
        }
        if (round[_contentHash][currRound][msg.sender] == true) {
            revert HasStaked();
        }
        round[_contentHash][currRound][msg.sender] = true;

        paymentToken.safeTransferFrom(msg.sender, address(this), _payment);
        upVote[_contentHash].push(
            VoteResult({voter: msg.sender, amount: initialStake})
        );

        proposal.proposeWeight = proposal.proposeWeight + calculateWeight(_payment);
        
        // Add the voter as a curator if they're not already
        if (!isCurator(_contentHash, msg.sender)) {
            proposal.curators.push(msg.sender);
        }
        
        if (currRound == 1) {
            proposal.state = ProposalState.Accepted;
            proposal.deadline = block.timestamp + (proposal.deadline - block.timestamp) * 7 / 10;
        } else if (proposal.proposeWeight >= proposal.disputeWeight * 2) {
            if (proposal.state != ProposalState.Accepted) {
                proposal.deadline = block.timestamp + period;
            }
            proposal.state = ProposalState.Accepted;
            proposal.roundIndex += 1;
        }
        emit ProposalProposed(
            _contentHash,
            msg.sender,
            proposal.contentURI,
            proposal.state,
            proposal.proposeWeight,
            proposal.disputeWeight,
            proposal.deadline,
            proposal.roundIndex,
            _payment,
            block.timestamp
        );
    }

    /// @notice Check if an address is a curator for a proposal
    /// @param _contentHash The hash of the content
    /// @param _address The address to check
    /// @return True if the address is a curator, false otherwise
    function isCurator(string memory _contentHash, address _address) internal view returns (bool) {
        Proposal storage proposal = proposals[_contentHash];
        for (uint256 i = 0; i < proposal.curators.length; i++) {
            if (proposal.curators[i] == _address) {
                return true;
            }
        }
        return false;
    }

    /// @notice Finalize a proposal after the voting period
    /// @param _contentHash The hash of the content to finalize
    function finalizeProposal(string memory _contentHash) external {
        Proposal storage proposal = proposals[_contentHash];

        if (proposal.state != ProposalState.Proposed && 
            proposal.state != ProposalState.Disputed &&
            proposal.state != ProposalState.Accepted) 
        {
            revert InvalidState();
        }

        if (block.timestamp < proposal.deadline) {
            revert ProposalPeriodNotEnded();
        }
        if (hashToTokenId[_contentHash] != 0) {
            revert ProposalHasReadyToMint();
        }
        if (uriToTokenId[proposal.contentURI] != 0) {
            revert ProposalURIExists();
        }

        uint256 downVoteLength = downVote[_contentHash].length;
        uint256 upVoteLength = upVote[_contentHash].length;

        if (proposal.state == ProposalState.Proposed) {    
            for (uint256 i = 0; i < upVoteLength; i++) {
                paymentToken.safeTransfer(
                    upVote[_contentHash][i].voter,
                    upVote[_contentHash][i].amount
                );
            }
            for (uint256 i = 0; i < downVoteLength; i++) {
                paymentToken.safeTransfer(
                    downVote[_contentHash][i].voter,
                    downVote[_contentHash][i].amount
                );
            }
            proposal.state = ProposalState.Abandoned;
            emit ProposalDisputed(
                _contentHash,
                address(0),
                proposal.contentURI,
                proposal.state,
                proposal.proposeWeight,
                proposal.disputeWeight,
                proposal.deadline,
                proposal.roundIndex,
                0,
                block.timestamp
            );
        } else if (proposal.state == ProposalState.Disputed) {
            // refound the downvote
            uint256 totalUpvote = 0;
            for (uint256 i = 0; i < upVoteLength; i++) {
                totalUpvote += upVote[_contentHash][i].amount;
            }
            uint256 downVoteWin = totalUpvote / downVoteLength;
            for (uint256 i = 0; i < downVoteLength; i++) {
                paymentToken.safeTransfer(
                    downVote[_contentHash][i].voter,
                    downVote[_contentHash][i].amount + downVoteWin
                );
            }
            proposal.state = ProposalState.Abandoned;
            emit ProposalDisputed(
                _contentHash,
                address(0),
                proposal.contentURI,
                proposal.state,
                proposal.proposeWeight,
                proposal.disputeWeight,
                proposal.deadline,
                proposal.roundIndex,
                0,
                block.timestamp
            );
        } else { // accepted
            uint256 totalDownvote = 0;
            for (uint256 i = 0; i < downVoteLength; i++) {
                totalDownvote += downVote[_contentHash][i].amount;
            }
            
            uint256 upVoteWin = totalDownvote / upVoteLength;
            for (uint256 i = 0; i < upVoteLength; i++) {
                paymentToken.safeTransfer(
                    upVote[_contentHash][i].voter,
                    upVote[_contentHash][i].amount + upVoteWin
                );
            }
            
            proposal.state = ProposalState.ReadyToMint;

            _tokenId.increment();
            uint256 newTokenId = _tokenId.current();
            tokenIdToContent[newTokenId] = Content({
                uuid: proposal.uuid,
                contentHash: proposal.contentHash,
                creator: proposal.contentCreator,
                createAt: block.timestamp,
                contentURI: proposal.contentURI
            });
            hashToTokenId[proposal.contentHash] = newTokenId;
            uriToTokenId[proposal.contentURI] = newTokenId;

            emit ProposalReadyToMint(
                _contentHash,
                hashToTokenId[_contentHash],
                proposal.roundIndex,
                block.timestamp,
                proposal.contentURI
            );
        }
    }

    /// @notice Get the URI for a token
    /// @param tokenId The ID of the token
    /// @return The URI of the token
    function getTokenURI(uint256 tokenId) public view returns (string memory) {
        if (!checkTokenIdValid(tokenId)) {
            revert InvalidTokenId();
        }
        return tokenIdToContent[tokenId].contentURI;
    }

    /// @notice Get the deadline for a token
    /// @param tokenId The ID of the token
    /// @return The deadline timestamp for the token
    function getTokenDeadline(uint256 tokenId) public view returns (uint256) {
        if (!checkTokenIdValid(tokenId)) {
            revert InvalidTokenId();
        }
        return tokenIdToContent[tokenId].createAt + deadlineDuration;
    }

    /// @notice Check if a token ID is valid
    /// @param tokenId The ID of the token to check
    /// @return True if the token ID is valid, false otherwise
    function checkTokenIdValid(uint256 tokenId) public view returns (bool) {
        if (tokenIdToContent[tokenId].creator == address(0)) {
            return false;
        }
        return true;
    }

    /// @notice Calculate the weight of a stake
    /// @param _stake The amount of tokens staked
    /// @return The calculated weight
    function calculateWeight(uint256 _stake) public pure returns (uint256) {
        return Math.sqrt(_stake);
    }

    /// @notice Get the fee recipients for a token
    /// @param tokenId The ID of the token
    /// @return _creator The address of the content creator
    /// @return _channelHost The address of the channel host
    function getFeeRecipients(uint256 tokenId) public view returns (address _creator, address _channelHost) {
        Content storage content = tokenIdToContent[tokenId];
        _creator = content.creator;
        _channelHost = channelHost;
    }

    /// @notice Calculate curator fees for a token
    /// @param tokenId The ID of the token
    /// @param totalCuratorFee The total fee to be distributed among curators
    /// @return An array of curator addresses
    /// @return An array of corresponding curator fees
    function calculateCuratorFees(uint256 tokenId, uint256 totalCuratorFee) public view returns (address[] memory, uint256[] memory) {
        string memory contentHash = tokenIdToContent[tokenId].contentHash;
        Proposal storage proposal = proposals[contentHash];
        uint256 curatorCount = proposal.curators.length;
        if (tokenId == 0 && curatorCount == 0) {
            revert NoCurators();
        }
        if (tokenId == 0 ){
            return (new address[](0), new uint256[](0));
        }

        uint256 paidCuratorsCount = Math.min(curatorCount, MAX_PAID_CURATORS);
        address[] memory curatorAddresses = new address[](paidCuratorsCount);
        uint256[] memory curatorFees = new uint256[](paidCuratorsCount);

        uint256 remainingFee = totalCuratorFee;
        uint256 share = 1 << (paidCuratorsCount - 1); // 2^(paidCuratorsCount-1)

        for (uint256 i = 0; i < paidCuratorsCount; i++) {
            curatorAddresses[i] = proposal.curators[i];
            
            if (i == paidCuratorsCount - 1) {
                curatorFees[i] = remainingFee;
            } else {
                curatorFees[i] = totalCuratorFee / share;
                remainingFee -= curatorFees[i];
                share = share / 2;
            }
        }

        return (curatorAddresses, curatorFees);
    }
}