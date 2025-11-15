// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "../src/MilestoneFactory.sol";
import "../src/MilestoneEscrow.sol";
import "../src/MockCUSD.sol";

/**
 * @title MilestoneEscrowTest
 * @dev Comprehensive tests for milestone-based escrow system
 */
contract MilestoneEscrowTest is Test {
    MilestoneFactory public factory;
    MockCUSD public usdc;

    address public admin;
    address public depositor;
    address public recipient;

    bytes32 public milestoneHash = keccak256("Milestone 1 document");
    uint256 public constant REFUND_GRACE_PERIOD = 3 days;

    event MilestoneCreated(
        address indexed milestoneAddress,
        address indexed depositor,
        address indexed recipient,
        uint256 amount,
        uint256 deadline,
        bytes32 milestoneHash,
        address token
    );
    event MilestoneFunded(uint256 amount, uint256 deadline);
    event MilestoneReleased(address indexed recipient, uint256 amount);
    event RefundRequested(address indexed depositor, uint256 requestedAt);
    event RefundExecuted(address indexed depositor, uint256 amount);
    event DisputeOpened(address indexed recipient, bytes32 disputeHash);
    event DisputeResolved(bool favorDepositor, bytes32 resolutionHash, uint256 payoutAmount);

    function setUp() public {
        // Setup test accounts
        admin = address(this);
        depositor = makeAddr("depositor");
        recipient = makeAddr("recipient");

        // Deploy mock USDC
        usdc = new MockCUSD();

        // Deploy factory (deploys implementation contract internally)
        factory = new MilestoneFactory(address(usdc));

        // Mint USDC to depositor for testing
        usdc.mint(depositor, 100000 * 10**6); // 100k USDC (6 decimals)

        // Approve factory to spend depositor's USDC
        vm.prank(depositor);
        usdc.approve(address(factory), type(uint256).max);
    }

    // ========== FACTORY TESTS ==========

    function test_FactoryDeployment() public view {
        assertEq(factory.admin(), admin, "Admin should be deployer");
        assertEq(factory.arbiter(), admin, "Arbiter should be initial admin");
        assertTrue(factory.isTokenSupported(address(usdc)), "USDC should be supported");
        assertEq(factory.totalMilestonesCreated(), 0, "Initial milestones count should be 0");
        assertTrue(factory.getImplementation() != address(0), "Implementation should be deployed");
    }

    function test_CreateMilestone() public {
        uint256 amount = 1000 * 10**6; // 1000 USDC
        uint256 deadline = block.timestamp + 7 days;

        uint256 depositorBalanceBefore = usdc.balanceOf(depositor);

        vm.prank(depositor);
        address milestoneAddress = factory.createMilestoneEscrow(
            recipient,
            address(usdc),
            amount,
            deadline,
            milestoneHash
        );

        // Verify milestone was created
        assertTrue(milestoneAddress != address(0), "Milestone should be created");
        assertTrue(factory.isValidMilestone(milestoneAddress), "Milestone should be valid");

        // Verify funds transferred (100% only, no fees)
        assertEq(
            usdc.balanceOf(depositor),
            depositorBalanceBefore - amount,
            "Depositor should pay 100%"
        );
        assertEq(usdc.balanceOf(milestoneAddress), amount, "Milestone should hold 100%");

        // Verify milestone state
        MilestoneEscrow milestone = MilestoneEscrow(milestoneAddress);
        assertEq(uint256(milestone.state()), 0, "State should be CREATED");
        assertEq(milestone.milestoneAmount(), amount, "Milestone amount should match");
        assertEq(milestone.deadline(), deadline, "Deadline should match");
        assertTrue(milestone.isInitialized(), "Milestone should be initialized");
    }

    function test_CannotCreateWithPastDeadline() public {
        uint256 amount = 1000 * 10**6;

        // Set current time first
        vm.warp(7 days);
        uint256 pastDeadline = block.timestamp - 1 days;

        vm.prank(depositor);
        vm.expectRevert("Deadline must be in future");
        factory.createMilestoneEscrow(
            recipient,
            address(usdc),
            amount,
            pastDeadline,
            milestoneHash
        );
    }

    function test_CannotCreateWithUnsupportedToken() public {
        address unsupportedToken = address(0x123);
        uint256 amount = 1000 * 10**6;
        uint256 deadline = block.timestamp + 7 days;

        vm.prank(depositor);
        vm.expectRevert("Token not supported");
        factory.createMilestoneEscrow(
            recipient,
            unsupportedToken,
            amount,
            deadline,
            milestoneHash
        );
    }

    // ========== HAPPY PATH: RELEASE ==========

    function test_Release() public {
        uint256 amount = 1000 * 10**6;
        uint256 deadline = block.timestamp + 7 days;

        // Create milestone
        vm.prank(depositor);
        address milestoneAddress = factory.createMilestoneEscrow(
            recipient,
            address(usdc),
            amount,
            deadline,
            milestoneHash
        );
        MilestoneEscrow milestone = MilestoneEscrow(milestoneAddress);

        uint256 recipientBalanceBefore = usdc.balanceOf(recipient);

        // Release payment
        vm.prank(depositor);
        milestone.release();

        // Verify state changed
        assertEq(uint256(milestone.state()), 1, "State should be RELEASED");

        // Verify funds transferred
        assertEq(
            usdc.balanceOf(recipient),
            recipientBalanceBefore + amount,
            "Recipient should receive 100%"
        );
        assertEq(usdc.balanceOf(milestoneAddress), 0, "Milestone should be empty");
    }

    function test_CannotReleaseAsNonDepositor() public {
        uint256 amount = 1000 * 10**6;
        uint256 deadline = block.timestamp + 7 days;

        vm.prank(depositor);
        address milestoneAddress = factory.createMilestoneEscrow(
            recipient,
            address(usdc),
            amount,
            deadline,
            milestoneHash
        );
        MilestoneEscrow milestone = MilestoneEscrow(milestoneAddress);

        // Try to release as recipient
        vm.prank(recipient);
        vm.expectRevert("Only depositor");
        milestone.release();
    }

    // ========== REFUND PATH ==========

    function test_RequestRefundAfterDeadline() public {
        uint256 amount = 1000 * 10**6;
        uint256 deadline = block.timestamp + 7 days;

        // Create milestone
        vm.prank(depositor);
        address milestoneAddress = factory.createMilestoneEscrow(
            recipient,
            address(usdc),
            amount,
            deadline,
            milestoneHash
        );
        MilestoneEscrow milestone = MilestoneEscrow(milestoneAddress);

        // Fast-forward past deadline
        vm.warp(deadline + 1);

        // Request refund
        vm.prank(depositor);
        milestone.requestRefund();

        // Verify state changed
        assertEq(uint256(milestone.state()), 2, "State should be REFUND_PENDING");
        assertEq(milestone.refundRequestedAt(), block.timestamp, "Refund requested timestamp should be set");
    }

    function test_CannotRequestRefundBeforeDeadline() public {
        uint256 amount = 1000 * 10**6;
        uint256 deadline = block.timestamp + 7 days;

        vm.prank(depositor);
        address milestoneAddress = factory.createMilestoneEscrow(
            recipient,
            address(usdc),
            amount,
            deadline,
            milestoneHash
        );
        MilestoneEscrow milestone = MilestoneEscrow(milestoneAddress);

        // Try to request refund before deadline
        vm.prank(depositor);
        vm.expectRevert("Deadline not reached");
        milestone.requestRefund();
    }

    function test_ExecuteRefundAfterGracePeriod() public {
        uint256 amount = 1000 * 10**6;
        uint256 deadline = block.timestamp + 7 days;

        // Create milestone
        vm.prank(depositor);
        address milestoneAddress = factory.createMilestoneEscrow(
            recipient,
            address(usdc),
            amount,
            deadline,
            milestoneHash
        );
        MilestoneEscrow milestone = MilestoneEscrow(milestoneAddress);

        // Request refund after deadline
        vm.warp(deadline + 1);
        vm.prank(depositor);
        milestone.requestRefund();

        uint256 refundRequestedAt = milestone.refundRequestedAt();

        // Fast-forward past grace period
        vm.warp(refundRequestedAt + REFUND_GRACE_PERIOD + 1);

        uint256 depositorBalanceBefore = usdc.balanceOf(depositor);

        // Execute refund (can be called by anyone)
        milestone.executeRefund();

        // Verify state changed
        assertEq(uint256(milestone.state()), 4, "State should be REFUNDED");

        // Verify funds returned
        assertEq(
            usdc.balanceOf(depositor),
            depositorBalanceBefore + amount,
            "Depositor should receive 100% back"
        );
        assertEq(usdc.balanceOf(milestoneAddress), 0, "Milestone should be empty");
    }

    function test_CannotExecuteRefundDuringGracePeriod() public {
        uint256 amount = 1000 * 10**6;
        uint256 deadline = block.timestamp + 7 days;

        vm.prank(depositor);
        address milestoneAddress = factory.createMilestoneEscrow(
            recipient,
            address(usdc),
            amount,
            deadline,
            milestoneHash
        );
        MilestoneEscrow milestone = MilestoneEscrow(milestoneAddress);

        // Request refund
        vm.warp(deadline + 1);
        vm.prank(depositor);
        milestone.requestRefund();

        // Try to execute immediately
        vm.expectRevert("Grace period not expired");
        milestone.executeRefund();

        // Try 1 day before grace period expires
        vm.warp(block.timestamp + REFUND_GRACE_PERIOD - 1);
        vm.expectRevert("Grace period not expired");
        milestone.executeRefund();
    }

    // ========== DISPUTE PATH ==========

    function test_DisputeRefundDuringGracePeriod() public {
        uint256 amount = 1000 * 10**6;
        uint256 deadline = block.timestamp + 7 days;

        // Create milestone
        vm.prank(depositor);
        address milestoneAddress = factory.createMilestoneEscrow(
            recipient,
            address(usdc),
            amount,
            deadline,
            milestoneHash
        );
        MilestoneEscrow milestone = MilestoneEscrow(milestoneAddress);

        // Request refund
        vm.warp(deadline + 1);
        vm.prank(depositor);
        milestone.requestRefund();

        // Recipient disputes during grace period
        bytes32 disputeHash = keccak256("I completed the work!");
        vm.prank(recipient);
        milestone.openDispute(disputeHash);

        // Verify state changed
        assertEq(uint256(milestone.state()), 3, "State should be DISPUTED");
        assertEq(milestone.disputeHash(), disputeHash, "Dispute hash should be set");
    }

    function test_CannotDisputeFromCreatedState() public {
        uint256 amount = 1000 * 10**6;
        uint256 deadline = block.timestamp + 7 days;

        vm.prank(depositor);
        address milestoneAddress = factory.createMilestoneEscrow(
            recipient,
            address(usdc),
            amount,
            deadline,
            milestoneHash
        );
        MilestoneEscrow milestone = MilestoneEscrow(milestoneAddress);

        // Try to dispute from CREATED state
        bytes32 disputeHash = keccak256("Dispute");
        vm.prank(recipient);
        vm.expectRevert("Invalid state");
        milestone.openDispute(disputeHash);
    }

    function test_CannotDisputeAsDepositor() public {
        uint256 amount = 1000 * 10**6;
        uint256 deadline = block.timestamp + 7 days;

        vm.prank(depositor);
        address milestoneAddress = factory.createMilestoneEscrow(
            recipient,
            address(usdc),
            amount,
            deadline,
            milestoneHash
        );
        MilestoneEscrow milestone = MilestoneEscrow(milestoneAddress);

        // Request refund
        vm.warp(deadline + 1);
        vm.prank(depositor);
        milestone.requestRefund();

        // Depositor tries to dispute (only recipient can)
        bytes32 disputeHash = keccak256("Dispute");
        vm.prank(depositor);
        vm.expectRevert("Only recipient");
        milestone.openDispute(disputeHash);
    }

    function test_CannotExecuteRefundAfterDispute() public {
        uint256 amount = 1000 * 10**6;
        uint256 deadline = block.timestamp + 7 days;

        vm.prank(depositor);
        address milestoneAddress = factory.createMilestoneEscrow(
            recipient,
            address(usdc),
            amount,
            deadline,
            milestoneHash
        );
        MilestoneEscrow milestone = MilestoneEscrow(milestoneAddress);

        // Request refund
        vm.warp(deadline + 1);
        vm.prank(depositor);
        milestone.requestRefund();

        // Recipient disputes
        bytes32 disputeHash = keccak256("Dispute");
        vm.prank(recipient);
        milestone.openDispute(disputeHash);

        // Fast-forward past grace period
        vm.warp(block.timestamp + REFUND_GRACE_PERIOD + 1);

        // Try to execute refund (should fail, state is DISPUTED)
        vm.expectRevert("Invalid state");
        milestone.executeRefund();
    }

    // ========== ARBITER RESOLUTION ==========

    function test_ArbiterResolveToRecipient() public {
        uint256 amount = 1000 * 10**6;
        uint256 deadline = block.timestamp + 7 days;

        vm.prank(depositor);
        address milestoneAddress = factory.createMilestoneEscrow(
            recipient,
            address(usdc),
            amount,
            deadline,
            milestoneHash
        );
        MilestoneEscrow milestone = MilestoneEscrow(milestoneAddress);

        // Request refund → Dispute
        vm.warp(deadline + 1);
        vm.prank(depositor);
        milestone.requestRefund();

        bytes32 disputeHash = keccak256("Dispute");
        vm.prank(recipient);
        milestone.openDispute(disputeHash);

        uint256 recipientBalanceBefore = usdc.balanceOf(recipient);

        // Arbiter resolves in favor of recipient
        bytes32 resolutionHash = keccak256("Resolution: Recipient completed work");
        vm.prank(admin);
        milestone.resolve(false, resolutionHash); // false = favor recipient

        // Verify state
        assertEq(uint256(milestone.state()), 1, "State should be RELEASED");

        // Verify funds
        assertEq(
            usdc.balanceOf(recipient),
            recipientBalanceBefore + amount,
            "Recipient should receive 100%"
        );
        assertEq(usdc.balanceOf(milestoneAddress), 0, "Milestone should be empty");
    }

    function test_ArbiterResolveToDepositor() public {
        uint256 amount = 1000 * 10**6;
        uint256 deadline = block.timestamp + 7 days;

        vm.prank(depositor);
        address milestoneAddress = factory.createMilestoneEscrow(
            recipient,
            address(usdc),
            amount,
            deadline,
            milestoneHash
        );
        MilestoneEscrow milestone = MilestoneEscrow(milestoneAddress);

        // Request refund → Dispute
        vm.warp(deadline + 1);
        vm.prank(depositor);
        milestone.requestRefund();

        bytes32 disputeHash = keccak256("Dispute");
        vm.prank(recipient);
        milestone.openDispute(disputeHash);

        uint256 depositorBalanceBefore = usdc.balanceOf(depositor);

        // Arbiter resolves in favor of depositor
        bytes32 resolutionHash = keccak256("Resolution: Work not completed");
        vm.prank(admin);
        milestone.resolve(true, resolutionHash); // true = favor depositor

        // Verify state
        assertEq(uint256(milestone.state()), 4, "State should be REFUNDED");

        // Verify funds
        assertEq(
            usdc.balanceOf(depositor),
            depositorBalanceBefore + amount,
            "Depositor should receive 100% back"
        );
        assertEq(usdc.balanceOf(milestoneAddress), 0, "Milestone should be empty");
    }

    function test_CannotResolveAsNonArbiter() public {
        uint256 amount = 1000 * 10**6;
        uint256 deadline = block.timestamp + 7 days;

        vm.prank(depositor);
        address milestoneAddress = factory.createMilestoneEscrow(
            recipient,
            address(usdc),
            amount,
            deadline,
            milestoneHash
        );
        MilestoneEscrow milestone = MilestoneEscrow(milestoneAddress);

        // Request refund → Dispute
        vm.warp(deadline + 1);
        vm.prank(depositor);
        milestone.requestRefund();

        bytes32 disputeHash = keccak256("Dispute");
        vm.prank(recipient);
        milestone.openDispute(disputeHash);

        // Try to resolve as depositor
        bytes32 resolutionHash = keccak256("Resolution");
        vm.prank(depositor);
        vm.expectRevert("Only arbiter");
        milestone.resolve(false, resolutionHash);
    }

    // ========== EDGE CASES ==========

    function test_ReleaseFromRefundPendingState() public {
        // Depositor can still release payment even after requesting refund
        uint256 amount = 1000 * 10**6;
        uint256 deadline = block.timestamp + 7 days;

        vm.prank(depositor);
        address milestoneAddress = factory.createMilestoneEscrow(
            recipient,
            address(usdc),
            amount,
            deadline,
            milestoneHash
        );
        MilestoneEscrow milestone = MilestoneEscrow(milestoneAddress);

        // Request refund
        vm.warp(deadline + 1);
        vm.prank(depositor);
        milestone.requestRefund();

        uint256 recipientBalanceBefore = usdc.balanceOf(recipient);

        // Change mind and release payment
        vm.prank(depositor);
        milestone.release();

        // Verify
        assertEq(uint256(milestone.state()), 1, "State should be RELEASED");
        assertEq(
            usdc.balanceOf(recipient),
            recipientBalanceBefore + amount,
            "Recipient should receive payment"
        );
    }

    function test_TimingInfoView() public {
        uint256 amount = 1000 * 10**6;
        uint256 deadline = block.timestamp + 7 days;

        vm.prank(depositor);
        address milestoneAddress = factory.createMilestoneEscrow(
            recipient,
            address(usdc),
            amount,
            deadline,
            milestoneHash
        );
        MilestoneEscrow milestone = MilestoneEscrow(milestoneAddress);

        // Check timing info before deadline
        (
            uint256 _deadline,
            uint256 _fundedAt,
            uint256 _refundRequestedAt,
            bool _canRequestRefund,
            bool _canExecuteRefund
        ) = milestone.getTimingInfo();

        assertEq(_deadline, deadline, "Deadline should match");
        assertTrue(_fundedAt > 0, "FundedAt should be set");
        assertEq(_refundRequestedAt, 0, "RefundRequestedAt should be 0");
        assertFalse(_canRequestRefund, "Cannot request refund before deadline");
        assertFalse(_canExecuteRefund, "Cannot execute refund");

        // Check after deadline
        vm.warp(deadline + 1);
        (,,, _canRequestRefund, _canExecuteRefund) = milestone.getTimingInfo();
        assertTrue(_canRequestRefund, "Can request refund after deadline");
        assertFalse(_canExecuteRefund, "Still cannot execute refund");

        // Request refund and check again
        vm.prank(depositor);
        milestone.requestRefund();

        (,,, _canRequestRefund, _canExecuteRefund) = milestone.getTimingInfo();
        assertFalse(_canRequestRefund, "Cannot request refund again");
        assertFalse(_canExecuteRefund, "Cannot execute refund during grace period");

        // Check after grace period
        vm.warp(block.timestamp + REFUND_GRACE_PERIOD + 1);
        (,,, _canRequestRefund, _canExecuteRefund) = milestone.getTimingInfo();
        assertTrue(_canExecuteRefund, "Can execute refund after grace period");
    }

    function test_MultipleTokenSupport() public {
        // Deploy another ERC20 token
        MockCUSD otherToken = new MockCUSD();

        // Add to factory
        vm.prank(admin);
        factory.addSupportedToken(address(otherToken));

        assertTrue(factory.isTokenSupported(address(otherToken)), "Token should be supported");

        // Mint and approve
        otherToken.mint(depositor, 10000 * 10**6);
        vm.prank(depositor);
        otherToken.approve(address(factory), type(uint256).max);

        // Create milestone with new token
        uint256 amount = 500 * 10**6;
        uint256 deadline = block.timestamp + 7 days;

        vm.prank(depositor);
        address milestoneAddress = factory.createMilestoneEscrow(
            recipient,
            address(otherToken),
            amount,
            deadline,
            milestoneHash
        );

        // Verify
        MilestoneEscrow milestone = MilestoneEscrow(milestoneAddress);
        assertEq(address(milestone.token()), address(otherToken), "Token should match");
        assertEq(otherToken.balanceOf(milestoneAddress), amount, "Funds should be locked");
    }

    function test_FactoryStatistics() public {
        uint256 amount1 = 1000 * 10**6;
        uint256 amount2 = 2000 * 10**6;
        uint256 deadline = block.timestamp + 7 days;

        // Create 2 milestones
        vm.startPrank(depositor);
        factory.createMilestoneEscrow(recipient, address(usdc), amount1, deadline, keccak256("M1"));
        factory.createMilestoneEscrow(recipient, address(usdc), amount2, deadline, keccak256("M2"));
        vm.stopPrank();

        // Check statistics
        (uint256 milestonesCreated, uint256 volumeProcessed) = factory.getStatistics();
        assertEq(milestonesCreated, 2, "Should have 2 milestones");
        assertEq(volumeProcessed, amount1 + amount2, "Volume should be sum of both");

        // Check user milestones
        address[] memory depositorMilestones = factory.getUserMilestones(depositor);
        assertEq(depositorMilestones.length, 2, "Depositor should have 2 milestones");

        address[] memory recipientMilestones = factory.getUserMilestones(recipient);
        assertEq(recipientMilestones.length, 2, "Recipient should have 2 milestones");
    }
}
