// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "./EscrowContract.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title MasterFactory
 * @dev Factory contract for creating and managing escrow contracts
 * @notice Part of SendHaven - P2P escrow protocol on Arc blockchain
 */
contract MasterFactory {
    using SafeERC20 for IERC20;
    address public admin;
    address public arbiter;
    address public immutable cUSDAddress;

    // Registry
    address[] public allEscrows;
    mapping(address => address[]) public userEscrows; // user -> their escrows
    mapping(address => bool) public isValidEscrow;

    // Statistics
    uint256 public totalEscrowsCreated;
    uint256 public totalVolumeProcessed;
    uint256 public totalFeesCollected;

    // Events
    event EscrowCreated(
        address indexed escrowAddress,
        address indexed depositor,
        address indexed recipient,
        uint256 amount,
        bytes32 deliverableHash
    );
    event ArbiterUpdated(address oldArbiter, address newArbiter);

    modifier onlyAdmin() {
        require(msg.sender == admin, "Only admin");
        _;
    }

    /**
     * @dev Constructor
     * @param _cUSDAddress Address of USDC token on Arc
     * Arc Testnet USDC: 0x3600000000000000000000000000000000000000
     */
    constructor(address _cUSDAddress) {
        admin = msg.sender;
        arbiter = msg.sender; // Admin is initial arbiter
        cUSDAddress = _cUSDAddress;
    }

    /**
     * @dev Create a new escrow contract
     * @param _recipient Address of the recipient
     * @param _amount Amount of USDC for the escrow
     * @param _deliverableHash Hash of the deliverable document
     * @return address Address of the created escrow contract
     */
    function createEscrow(
        address _recipient,
        uint256 _amount,
        bytes32 _deliverableHash
    ) external returns (address) {
        require(_recipient != address(0) && _recipient != msg.sender, "Invalid recipient");
        require(_amount > 0, "Amount must be greater than 0");
        require(_deliverableHash != bytes32(0), "Deliverable hash required");

        // Deploy new escrow contract
        EscrowContract escrow = new EscrowContract(
            msg.sender,        // depositor
            _recipient,
            _amount,
            _deliverableHash,
            arbiter,
            cUSDAddress
        );

        address escrowAddress = address(escrow);

        // Calculate total amount needed (105% = amount + 1% fee + 4% bond)
        uint256 totalRequired = _amount +
                               (_amount * 100) / 10000 +  // 1% platform fee
                               (_amount * 400) / 10000;    // 4% dispute bond

        // Transfer tokens from depositor to escrow contract
        IERC20(cUSDAddress).safeTransferFrom(msg.sender, escrowAddress, totalRequired);

        // Update registry
        allEscrows.push(escrowAddress);
        userEscrows[msg.sender].push(escrowAddress);
        userEscrows[_recipient].push(escrowAddress);
        isValidEscrow[escrowAddress] = true;

        // Update statistics
        totalEscrowsCreated++;
        totalVolumeProcessed += _amount;

        emit EscrowCreated(
            escrowAddress,
            msg.sender,
            _recipient,
            _amount,
            _deliverableHash
        );

        return escrowAddress;
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

    /**
     * @dev Callback from escrow contracts to update fee statistics
     * @param feeAmount Amount of fees collected
     */
    function reportFeeCollection(uint256 feeAmount) external {
        require(isValidEscrow[msg.sender], "Only valid escrows");
        totalFeesCollected += feeAmount;
    }

    // View functions

    /**
     * @dev Get all escrows for a specific user
     * @param user User address
     * @return Array of escrow addresses
     */
    function getUserEscrows(address user) external view returns (address[] memory) {
        return userEscrows[user];
    }

    /**
     * @dev Get all escrows created through this factory
     * @return Array of all escrow addresses
     */
    function getAllEscrows() external view returns (address[] memory) {
        return allEscrows;
    }

    /**
     * @dev Get factory statistics
     * @return escrowsCreated Total number of escrows created
     * @return volumeProcessed Total volume processed
     * @return feesCollected Total fees collected
     */
    function getStatistics() external view returns (
        uint256 escrowsCreated,
        uint256 volumeProcessed,
        uint256 feesCollected
    ) {
        return (totalEscrowsCreated, totalVolumeProcessed, totalFeesCollected);
    }
}
