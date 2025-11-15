// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface IFactory {
    function reportFeeCollection(uint256 feeAmount) external;
}

/**
 * @title EscrowContract
 * @dev Individual escrow contract with dispute resolution
 * @notice Part of SendHaven - P2P escrow protocol on Arc blockchain
 */
contract EscrowContract is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // Constants
    uint256 public constant PLATFORM_FEE_BPS = 100;  // 1%
    uint256 public constant DISPUTE_BOND_BPS = 400;  // 4%
    uint256 private constant BPS_DENOMINATOR = 10000;

    // State
    enum EscrowState { CREATED, DISPUTED, COMPLETED, REFUNDED }

    // Core data
    address public immutable factory;
    address public immutable depositor;
    address public immutable recipient;
    address public immutable arbiter;
    IERC20 public immutable token;

    uint256 public immutable escrowAmount;    // The actual escrow (100%)
    uint256 public immutable platformFee;     // 1% of escrowAmount
    uint256 public immutable disputeBond;     // 4% of escrowAmount
    uint256 public immutable totalDeposited;  // 105% total
    uint256 public immutable createdAt;

    bytes32 public immutable deliverableHash;

    // Mutable state
    EscrowState public state;
    bytes32 public disputeReasonHash;
    bytes32 public resolutionHash;

    // Events
    event EscrowFunded(uint256 amount, uint256 fee, uint256 bond);
    event EscrowCompleted(address indexed recipient, uint256 amount);
    event EscrowRefunded(address indexed depositor, uint256 amount);
    event DisputeRaised(address indexed raiser, bytes32 disputeReasonHash);
    event DisputeResolved(
        bool favorDepositor,
        bytes32 resolutionHash,
        uint256 payoutAmount,
        uint256 feeAmount
    );

    modifier onlyDepositor() {
        require(msg.sender == depositor, "Only depositor");
        _;
    }

    modifier onlyArbiter() {
        require(msg.sender == arbiter, "Only arbiter");
        _;
    }

    modifier onlyParties() {
        require(
            msg.sender == depositor || msg.sender == recipient,
            "Only parties"
        );
        _;
    }

    modifier inState(EscrowState _state) {
        require(state == _state, "Invalid state");
        _;
    }

    constructor(
        address _depositor,
        address _recipient,
        uint256 _amount,
        bytes32 _deliverableHash,
        address _arbiter,
        address _tokenAddress
    ) {
        require(_depositor != address(0), "Invalid depositor");
        require(_recipient != address(0), "Invalid recipient");
        require(_amount > 0, "Amount must be greater than 0");
        require(_deliverableHash != bytes32(0), "Deliverable hash required");
        require(_arbiter != address(0), "Invalid arbiter");
        require(_tokenAddress != address(0), "Invalid token address");

        factory = msg.sender;
        depositor = _depositor;
        recipient = _recipient;
        arbiter = _arbiter;
        token = IERC20(_tokenAddress);

        escrowAmount = _amount;
        platformFee = (_amount * PLATFORM_FEE_BPS) / BPS_DENOMINATOR;
        disputeBond = (_amount * DISPUTE_BOND_BPS) / BPS_DENOMINATOR;
        totalDeposited = _amount + platformFee + disputeBond;

        deliverableHash = _deliverableHash;
        createdAt = block.timestamp;
        state = EscrowState.CREATED;

        // Note: Factory will transfer funds after deployment
        emit EscrowFunded(escrowAmount, platformFee, disputeBond);
    }

    // Core Functions

    function complete() external onlyDepositor inState(EscrowState.CREATED) nonReentrant {
        state = EscrowState.COMPLETED;

        // Transfer escrow amount to recipient
        token.safeTransfer(recipient, escrowAmount);

        // Transfer platform fee to arbiter
        token.safeTransfer(arbiter, platformFee);

        // Return dispute bond to depositor
        token.safeTransfer(depositor, disputeBond);

        // Report fee collection to factory
        IFactory(factory).reportFeeCollection(platformFee);

        emit EscrowCompleted(recipient, escrowAmount);
    }

    function dispute(bytes32 _disputeReasonHash) external onlyParties inState(EscrowState.CREATED) {
        require(_disputeReasonHash != bytes32(0), "Dispute reason hash required");

        state = EscrowState.DISPUTED;
        disputeReasonHash = _disputeReasonHash;

        emit DisputeRaised(msg.sender, _disputeReasonHash);
    }

    function resolve(
        bool favorDepositor,
        bytes32 _resolutionHash
    ) external onlyArbiter inState(EscrowState.DISPUTED) nonReentrant {
        require(_resolutionHash != bytes32(0), "Resolution hash required");

        resolutionHash = _resolutionHash;

        if (favorDepositor) {
            state = EscrowState.REFUNDED;

            // Refund escrow amount to depositor
            token.safeTransfer(depositor, escrowAmount);

            // Depositor also gets their dispute bond back
            token.safeTransfer(depositor, disputeBond);

            // Arbiter gets platform fee only
            token.safeTransfer(arbiter, platformFee);

            IFactory(factory).reportFeeCollection(platformFee);

            emit DisputeResolved(true, _resolutionHash, escrowAmount + disputeBond, platformFee);
            emit EscrowRefunded(depositor, escrowAmount);

        } else {
            state = EscrowState.COMPLETED;

            // Transfer escrow amount to recipient
            token.safeTransfer(recipient, escrowAmount);

            // Arbiter gets platform fee + dispute bond
            uint256 totalArbitrationFee = platformFee + disputeBond;
            token.safeTransfer(arbiter, totalArbitrationFee);

            IFactory(factory).reportFeeCollection(totalArbitrationFee);

            emit DisputeResolved(false, _resolutionHash, escrowAmount, totalArbitrationFee);
            emit EscrowCompleted(recipient, escrowAmount);
        }
    }

    // View functions

    function getDetails() external view returns (
        address _depositor,
        address _recipient,
        uint256 _escrowAmount,
        uint256 _platformFee,
        uint256 _disputeBond,
        EscrowState _state,
        bytes32 _deliverableHash,
        uint256 _createdAt
    ) {
        return (
            depositor,
            recipient,
            escrowAmount,
            platformFee,
            disputeBond,
            state,
            deliverableHash,
            createdAt
        );
    }

    function getDisputeInfo() external view returns (
        bytes32 _disputeReasonHash,
        bytes32 _resolutionHash
    ) {
        return (disputeReasonHash, resolutionHash);
    }

    function getTotalValue() external view returns (uint256) {
        return escrowAmount + platformFee + disputeBond;
    }

    function getContractBalance() external view returns (uint256) {
        return token.balanceOf(address(this));
    }
}
