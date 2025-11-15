// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "../src/MasterFactory.sol";
import "../src/EscrowContract.sol";
import "../src/MockCUSD.sol";

/**
 * @title SendHavenTest
 * @dev Smoke tests for SendHaven escrow protocol
 */
contract SendHavenTest is Test {
    MasterFactory public factory;
    MockCUSD public usdc;

    address public admin;
    address public depositor;
    address public recipient;

    bytes32 public deliverableHash = keccak256("Deliverable document");

    function setUp() public {
        // Setup test accounts
        admin = address(this);
        depositor = makeAddr("depositor");
        recipient = makeAddr("recipient");

        // Deploy mock USDC
        usdc = new MockCUSD();

        // Deploy factory
        factory = new MasterFactory(address(usdc));

        // Mint USDC to depositor for testing
        usdc.mint(depositor, 100000 * 10**6); // 100k USDC (6 decimals)

        // Approve factory to spend depositor's USDC
        vm.prank(depositor);
        usdc.approve(address(factory), type(uint256).max);
    }

    /**
     * Test 1: Factory deployment & initialization
     */
    function test_FactoryDeploymentAndInitialization() public view {
        assertEq(factory.admin(), admin, "Admin should be deployer");
        assertEq(factory.arbiter(), admin, "Arbiter should be initial admin");
        assertEq(factory.cUSDAddress(), address(usdc), "USDC address should match");
        assertEq(factory.totalEscrowsCreated(), 0, "Initial escrows count should be 0");
    }

    /**
     * Test 2: Create escrow (verify funds locked)
     */
    function test_CreateEscrow() public {
        uint256 amount = 1000 * 10**6; // 1000 USDC
        uint256 platformFee = (amount * 100) / 10000; // 1%
        uint256 disputeBond = (amount * 400) / 10000; // 4%
        uint256 totalRequired = amount + platformFee + disputeBond; // 105%

        uint256 depositorBalanceBefore = usdc.balanceOf(depositor);

        vm.prank(depositor);
        address escrowAddress = factory.createEscrow(recipient, amount, deliverableHash);

        // Verify escrow was created
        assertTrue(escrowAddress != address(0), "Escrow should be created");
        assertTrue(factory.isValidEscrow(escrowAddress), "Escrow should be valid");

        // Verify funds transferred
        assertEq(
            usdc.balanceOf(depositor),
            depositorBalanceBefore - totalRequired,
            "Depositor should pay 105%"
        );
        assertEq(usdc.balanceOf(escrowAddress), totalRequired, "Escrow should hold 105%");

        // Verify escrow state
        EscrowContract escrow = EscrowContract(escrowAddress);
        assertEq(uint256(escrow.state()), 0, "State should be CREATED");
        assertEq(escrow.escrowAmount(), amount, "Escrow amount should match");
    }

    /**
     * Test 3: Complete escrow (verify fund distribution)
     */
    function test_CompleteEscrow() public {
        uint256 amount = 1000 * 10**6; // 1000 USDC

        // Create escrow
        vm.prank(depositor);
        address escrowAddress = factory.createEscrow(recipient, amount, deliverableHash);
        EscrowContract escrow = EscrowContract(escrowAddress);

        uint256 recipientBalanceBefore = usdc.balanceOf(recipient);
        uint256 depositorBalanceBefore = usdc.balanceOf(depositor);
        uint256 arbiterBalanceBefore = usdc.balanceOf(admin);

        // Complete escrow
        vm.prank(depositor);
        escrow.complete();

        // Verify state changed
        assertEq(uint256(escrow.state()), 2, "State should be COMPLETED");

        // Verify fund distribution
        assertEq(
            usdc.balanceOf(recipient),
            recipientBalanceBefore + amount,
            "Recipient should receive 100%"
        );
        assertEq(
            usdc.balanceOf(depositor),
            depositorBalanceBefore + escrow.disputeBond(),
            "Depositor should get 4% bond back"
        );
        assertEq(
            usdc.balanceOf(admin),
            arbiterBalanceBefore + escrow.platformFee(),
            "Arbiter should get 1% fee"
        );
        assertEq(usdc.balanceOf(escrowAddress), 0, "Escrow should be empty");
    }

    /**
     * Test 4: Dispute → Resolve to recipient
     */
    function test_DisputeResolveToRecipient() public {
        uint256 amount = 1000 * 10**6; // 1000 USDC

        // Create escrow
        vm.prank(depositor);
        address escrowAddress = factory.createEscrow(recipient, amount, deliverableHash);
        EscrowContract escrow = EscrowContract(escrowAddress);

        // Raise dispute
        bytes32 disputeHash = keccak256("Dispute reason");
        vm.prank(depositor);
        escrow.dispute(disputeHash);
        assertEq(uint256(escrow.state()), 1, "State should be DISPUTED");

        uint256 recipientBalanceBefore = usdc.balanceOf(recipient);
        uint256 arbiterBalanceBefore = usdc.balanceOf(admin);

        // Arbiter resolves in favor of recipient
        bytes32 resolutionHash = keccak256("Resolution");
        vm.prank(admin);
        escrow.resolve(false, resolutionHash); // false = favor recipient

        // Verify state
        assertEq(uint256(escrow.state()), 2, "State should be COMPLETED");

        // Verify fund distribution
        assertEq(
            usdc.balanceOf(recipient),
            recipientBalanceBefore + amount,
            "Recipient should get 100%"
        );
        assertEq(
            usdc.balanceOf(admin),
            arbiterBalanceBefore + escrow.platformFee() + escrow.disputeBond(),
            "Arbiter should get 1% fee + 4% bond (5% total)"
        );
    }

    /**
     * Test 5: Dispute → Resolve to depositor
     */
    function test_DisputeResolveToDepositor() public {
        uint256 amount = 1000 * 10**6; // 1000 USDC

        // Create escrow
        vm.prank(depositor);
        address escrowAddress = factory.createEscrow(recipient, amount, deliverableHash);
        EscrowContract escrow = EscrowContract(escrowAddress);

        // Raise dispute
        bytes32 disputeHash = keccak256("Dispute reason");
        vm.prank(recipient);
        escrow.dispute(disputeHash);
        assertEq(uint256(escrow.state()), 1, "State should be DISPUTED");

        uint256 depositorBalanceBefore = usdc.balanceOf(depositor);
        uint256 arbiterBalanceBefore = usdc.balanceOf(admin);

        // Arbiter resolves in favor of depositor
        bytes32 resolutionHash = keccak256("Resolution");
        vm.prank(admin);
        escrow.resolve(true, resolutionHash); // true = favor depositor

        // Verify state
        assertEq(uint256(escrow.state()), 3, "State should be REFUNDED");

        // Verify fund distribution
        assertEq(
            usdc.balanceOf(depositor),
            depositorBalanceBefore + amount + escrow.disputeBond(),
            "Depositor should get 100% + 4% bond back (104% total)"
        );
        assertEq(
            usdc.balanceOf(admin),
            arbiterBalanceBefore + escrow.platformFee(),
            "Arbiter should get 1% fee only"
        );
    }
}
