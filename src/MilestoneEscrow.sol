// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title MilestoneEscrow
 * @dev Individual milestone escrow with deadline-based refunds and dispute protection
 * @notice Part of SendHaven - Per-milestone escrow system for freelance work
 *
 * Key Features:
 * - Depositor sets milestone deadline at creation
 * - After deadline: depositor can request refund
 * - 3-day grace period: recipient can dispute refund request
 * - If disputed: arbiter resolves off-chain dispute
 * - Designed for EIP-1167 minimal proxy cloning
 */
contract MilestoneEscrow is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // Constants
    uint256 public constant REFUND_GRACE_PERIOD = 3 days;

    // State machine
    enum MilestoneState {
        CREATED,        // 0 - Milestone funded, work in progress
        RELEASED,       // 1 - Payment released to recipient (happy path)
        REFUND_PENDING, // 2 - Refund requested, grace period active
        DISPUTED,       // 3 - Recipient disputed refund, awaiting arbitration
        REFUNDED        // 4 - Funds returned to depositor
    }

    // Core data (set via initialize for proxy pattern)
    address public factory;
    address public depositor;
    address public recipient;
    address public arbiter;
    IERC20 public token;

    uint256 public milestoneAmount;  // 100% payment amount
    uint256 public deadline;         // Depositor-set work deadline (timestamp)
    uint256 public fundedAt;         // When milestone was funded

    bytes32 public milestoneHash;    // Hash of milestone metadata

    // Mutable state
    MilestoneState public state;
    uint256 public refundRequestedAt;          // When refund was requested (0 if not requested)
    bytes32 public disputeHash;                // Hash of dispute reason
    bytes32 public resolutionHash;             // Hash of arbiter resolution

    // Initialization flag (prevent re-initialization)
    bool private initialized;

    // Events
    event MilestoneFunded(uint256 amount, uint256 deadline);
    event MilestoneReleased(address indexed recipient, uint256 amount);
    event RefundRequested(address indexed depositor, uint256 requestedAt);
    event RefundExecuted(address indexed depositor, uint256 amount);
    event DisputeOpened(address indexed recipient, bytes32 disputeHash);
    event DisputeResolved(
        bool favorDepositor,
        bytes32 resolutionHash,
        uint256 payoutAmount
    );

    // Modifiers
    modifier onlyDepositor() {
        require(msg.sender == depositor, "Only depositor");
        _;
    }

    modifier onlyRecipient() {
        require(msg.sender == recipient, "Only recipient");
        _;
    }

    modifier onlyArbiter() {
        require(msg.sender == arbiter, "Only arbiter");
        _;
    }

    modifier inState(MilestoneState _state) {
        require(state == _state, "Invalid state");
        _;
    }

    /**
     * @dev Initialize the milestone escrow (called once per clone)
     * @notice This function replaces constructor for proxy pattern compatibility
     */
    function initialize(
        address _depositor,
        address _recipient,
        uint256 _amount,
        uint256 _deadline,
        bytes32 _milestoneHash,
        address _arbiter,
        address _tokenAddress
    ) external {
        require(!initialized, "Already initialized");
        require(_depositor != address(0), "Invalid depositor");
        require(_recipient != address(0), "Invalid recipient");
        require(_amount > 0, "Amount must be > 0");
        require(_deadline > block.timestamp, "Deadline must be in future");
        require(_milestoneHash != bytes32(0), "Milestone hash required");
        require(_arbiter != address(0), "Invalid arbiter");
        require(_tokenAddress != address(0), "Invalid token");

        initialized = true;
        factory = msg.sender;
        depositor = _depositor;
        recipient = _recipient;
        arbiter = _arbiter;
        token = IERC20(_tokenAddress);

        milestoneAmount = _amount;
        deadline = _deadline;
        fundedAt = block.timestamp;
        milestoneHash = _milestoneHash;

        state = MilestoneState.CREATED;

        emit MilestoneFunded(_amount, _deadline);
    }

    // ========== CORE FUNCTIONS ==========

    /**
     * @notice Release payment to recipient (happy path)
     * @dev Can be called by depositor at any time in CREATED or REFUND_PENDING state
     */
    function release()
        external
        onlyDepositor
        nonReentrant
    {
        require(
            state == MilestoneState.CREATED || state == MilestoneState.REFUND_PENDING,
            "Can only release from CREATED or REFUND_PENDING"
        );

        state = MilestoneState.RELEASED;
        token.safeTransfer(recipient, milestoneAmount);

        emit MilestoneReleased(recipient, milestoneAmount);
    }

    /**
     * @notice Request refund after deadline expires
     * @dev Starts 3-day grace period for recipient to dispute
     */
    function requestRefund()
        external
        onlyDepositor
        inState(MilestoneState.CREATED)
    {
        require(block.timestamp >= deadline, "Deadline not reached");

        state = MilestoneState.REFUND_PENDING;
        refundRequestedAt = block.timestamp;

        emit RefundRequested(depositor, block.timestamp);
    }

    /**
     * @notice Execute refund after grace period expires
     * @dev Can be called by anyone after 3-day grace period
     */
    function executeRefund()
        external
        inState(MilestoneState.REFUND_PENDING)
        nonReentrant
    {
        require(
            block.timestamp >= refundRequestedAt + REFUND_GRACE_PERIOD,
            "Grace period not expired"
        );

        state = MilestoneState.REFUNDED;
        token.safeTransfer(depositor, milestoneAmount);

        emit RefundExecuted(depositor, milestoneAmount);
    }

    /**
     * @notice Recipient disputes refund request during grace period
     * @dev Cancels auto-refund, locks funds for arbiter resolution
     * @param _disputeHash Hash of dispute reason stored off-chain
     */
    function openDispute(bytes32 _disputeHash)
        external
        onlyRecipient
        inState(MilestoneState.REFUND_PENDING)
    {
        require(_disputeHash != bytes32(0), "Dispute hash required");

        state = MilestoneState.DISPUTED;
        disputeHash = _disputeHash;

        emit DisputeOpened(recipient, _disputeHash);
    }

    /**
     * @notice Arbiter resolves dispute
     * @dev Can only be called in DISPUTED state
     * @param favorDepositor True = refund to depositor, False = release to recipient
     * @param _resolutionHash Hash of resolution document stored off-chain
     */
    function resolve(
        bool favorDepositor,
        bytes32 _resolutionHash
    )
        external
        onlyArbiter
        inState(MilestoneState.DISPUTED)
        nonReentrant
    {
        require(_resolutionHash != bytes32(0), "Resolution hash required");

        resolutionHash = _resolutionHash;

        if (favorDepositor) {
            state = MilestoneState.REFUNDED;
            token.safeTransfer(depositor, milestoneAmount);
            emit RefundExecuted(depositor, milestoneAmount);
        } else {
            state = MilestoneState.RELEASED;
            token.safeTransfer(recipient, milestoneAmount);
            emit MilestoneReleased(recipient, milestoneAmount);
        }

        emit DisputeResolved(favorDepositor, _resolutionHash, milestoneAmount);
    }

    // ========== VIEW FUNCTIONS ==========

    function getDetails() external view returns (
        address _depositor,
        address _recipient,
        uint256 _milestoneAmount,
        uint256 _deadline,
        uint256 _fundedAt,
        MilestoneState _state,
        bytes32 _milestoneHash
    ) {
        return (
            depositor,
            recipient,
            milestoneAmount,
            deadline,
            fundedAt,
            state,
            milestoneHash
        );
    }

    function getTimingInfo() external view returns (
        uint256 _deadline,
        uint256 _fundedAt,
        uint256 _refundRequestedAt,
        bool _canRequestRefund,
        bool _canExecuteRefund
    ) {
        bool canRequest = (state == MilestoneState.CREATED && block.timestamp >= deadline);
        bool canExecute = (
            state == MilestoneState.REFUND_PENDING &&
            block.timestamp >= refundRequestedAt + REFUND_GRACE_PERIOD
        );

        return (
            deadline,
            fundedAt,
            refundRequestedAt,
            canRequest,
            canExecute
        );
    }

    function getDisputeInfo() external view returns (
        bytes32 _disputeHash,
        bytes32 _resolutionHash
    ) {
        return (disputeHash, resolutionHash);
    }

    function getContractBalance() external view returns (uint256) {
        return token.balanceOf(address(this));
    }

    function isInitialized() external view returns (bool) {
        return initialized;
    }
}
