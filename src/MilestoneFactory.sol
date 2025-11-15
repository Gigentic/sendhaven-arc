// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "./MilestoneEscrow.sol";
import "@openzeppelin/contracts/proxy/Clones.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title MilestoneFactory
 * @dev Factory for creating milestone escrows using EIP-1167 minimal proxies
 * @notice Part of SendHaven - Per-milestone escrow system
 *
 * Gas Optimization:
 * - Uses minimal proxy pattern (EIP-1167) to reduce deployment costs ~90%
 * - Implementation contract deployed once, clones reference it
 * - Each milestone creation ~200K gas vs ~2M gas for full deployment
 */
contract MilestoneFactory {
    using SafeERC20 for IERC20;
    using Clones for address;

    // Roles
    address public admin;
    address public arbiter;

    // Implementation contract for cloning
    address public immutable implementation;

    // Registry
    address[] public allMilestones;
    mapping(address => address[]) public userMilestones; // user -> their milestones
    mapping(address => bool) public isValidMilestone;

    // Supported tokens
    mapping(address => bool) public supportedTokens;

    // Statistics
    uint256 public totalMilestonesCreated;
    uint256 public totalVolumeProcessed;

    // Events
    event MilestoneCreated(
        address indexed milestoneAddress,
        address indexed depositor,
        address indexed recipient,
        uint256 amount,
        uint256 deadline,
        bytes32 milestoneHash,
        address token
    );
    event ArbiterUpdated(address oldArbiter, address newArbiter);
    event TokenAdded(address indexed token);
    event TokenRemoved(address indexed token);

    modifier onlyAdmin() {
        require(msg.sender == admin, "Only admin");
        _;
    }

    /**
     * @dev Constructor - deploys implementation contract
     * @param _defaultTokenAddress Default token (USDC on Arc)
     * Arc Testnet USDC: 0x3600000000000000000000000000000000000000
     */
    constructor(address _defaultTokenAddress) {
        require(_defaultTokenAddress != address(0), "Invalid token");

        admin = msg.sender;
        arbiter = msg.sender; // Admin is initial arbiter

        // Deploy implementation contract for cloning
        // Note: Implementation is never initialized, only used as a template
        implementation = address(new MilestoneEscrow());

        // Add default token
        supportedTokens[_defaultTokenAddress] = true;
        emit TokenAdded(_defaultTokenAddress);
    }

    /**
     * @dev Create a new milestone escrow using minimal proxy
     * @param _recipient Address of the freelancer
     * @param _tokenAddress ERC20 token to use (must be supported)
     * @param _amount Milestone payment amount (100%, no fees)
     * @param _deadline Unix timestamp for milestone deadline
     * @param _milestoneHash Hash of milestone metadata (stored off-chain)
     * @return address Address of the created milestone escrow
     */
    function createMilestoneEscrow(
        address _recipient,
        address _tokenAddress,
        uint256 _amount,
        uint256 _deadline,
        bytes32 _milestoneHash
    ) external returns (address) {
        require(_recipient != address(0) && _recipient != msg.sender, "Invalid recipient");
        require(_amount > 0, "Amount must be > 0");
        require(_deadline > block.timestamp, "Deadline must be in future");
        require(_milestoneHash != bytes32(0), "Milestone hash required");
        require(supportedTokens[_tokenAddress], "Token not supported");

        // Clone implementation using minimal proxy (EIP-1167)
        address clone = implementation.clone();

        // Initialize the clone with actual parameters
        MilestoneEscrow(clone).initialize(
            msg.sender,      // depositor
            _recipient,
            _amount,
            _deadline,
            _milestoneHash,
            arbiter,
            _tokenAddress
        );

        // Transfer tokens from depositor to milestone contract (100% only, no fees)
        IERC20(_tokenAddress).safeTransferFrom(msg.sender, clone, _amount);

        // Update registry
        allMilestones.push(clone);
        userMilestones[msg.sender].push(clone);
        userMilestones[_recipient].push(clone);
        isValidMilestone[clone] = true;

        // Update statistics
        totalMilestonesCreated++;
        totalVolumeProcessed += _amount;

        emit MilestoneCreated(
            clone,
            msg.sender,
            _recipient,
            _amount,
            _deadline,
            _milestoneHash,
            _tokenAddress
        );

        return clone;
    }

    /**
     * @dev Add a supported token
     * @param _token Token address to add
     */
    function addSupportedToken(address _token) external onlyAdmin {
        require(_token != address(0), "Invalid token");
        require(!supportedTokens[_token], "Token already supported");

        supportedTokens[_token] = true;
        emit TokenAdded(_token);
    }

    /**
     * @dev Remove a supported token
     * @param _token Token address to remove
     */
    function removeSupportedToken(address _token) external onlyAdmin {
        require(supportedTokens[_token], "Token not supported");

        supportedTokens[_token] = false;
        emit TokenRemoved(_token);
    }

    /**
     * @dev Update the arbiter address
     * @param _newArbiter New arbiter address
     */
    function updateArbiter(address _newArbiter) external onlyAdmin {
        require(_newArbiter != address(0), "Invalid arbiter");
        address oldArbiter = arbiter;
        arbiter = _newArbiter;
        emit ArbiterUpdated(oldArbiter, _newArbiter);
    }

    // ========== VIEW FUNCTIONS ==========

    /**
     * @dev Get all milestones for a specific user
     * @param user User address
     * @return Array of milestone addresses
     */
    function getUserMilestones(address user) external view returns (address[] memory) {
        return userMilestones[user];
    }

    /**
     * @dev Get all milestones created through this factory
     * @return Array of all milestone addresses
     */
    function getAllMilestones() external view returns (address[] memory) {
        return allMilestones;
    }

    /**
     * @dev Get factory statistics
     * @return milestonesCreated Total number of milestones created
     * @return volumeProcessed Total volume processed
     */
    function getStatistics() external view returns (
        uint256 milestonesCreated,
        uint256 volumeProcessed
    ) {
        return (totalMilestonesCreated, totalVolumeProcessed);
    }

    /**
     * @dev Check if a token is supported
     * @param _token Token address to check
     * @return bool True if token is supported
     */
    function isTokenSupported(address _token) external view returns (bool) {
        return supportedTokens[_token];
    }

    /**
     * @dev Get the implementation contract address
     * @return address Implementation contract address
     */
    function getImplementation() external view returns (address) {
        return implementation;
    }
}
