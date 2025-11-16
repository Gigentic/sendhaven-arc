# SendHaven Smart Contracts

> Solidity smart contracts for SendHaven's cross-chain escrow protocol on Arc Testnet

This repository contains the Foundry-based smart contracts that power SendHaven's peer-to-peer escrow system. All escrows are deployed on Arc Testnet, leveraging Arc's unique USDC-native gas fee structure for cost-effective transactions.

## Overview

SendHaven uses a **factory pattern** to deploy individual escrow contracts:

- **MasterFactory**: Central factory that creates and tracks all escrow instances
- **EscrowContract**: Individual escrow with 4-state lifecycle and hash-based deliverable verification
- **MilestoneEscrow**: (Experimental) Multi-milestone escrow for complex projects
- **MilestoneFactory**: Factory for milestone-based escrows

## Architecture

### MasterFactory

The factory contract manages escrow creation and global configuration.

**Key Functions:**
- `createEscrow(recipient, amount, deliverableHash)`: Deploy new escrow instance
- `updateArbiter(newArbiter)`: Update global arbiter address (admin only)
- `withdrawFees(amount)`: Withdraw accumulated platform fees (admin only)

**Registry:**
- `allEscrows[]`: Array of all created escrow addresses
- `userEscrows[user]`: Mapping of user addresses to their escrows
- `isValidEscrow[address]`: Validation check for escrow addresses

**Statistics:**
- `totalEscrowsCreated`: Count of all escrows created
- `totalVolumeProcessed`: Total USDC processed through escrows
- `totalFeesCollected`: Accumulated platform fees

**Events:**
```solidity
event EscrowCreated(
    address indexed escrowAddress,
    address indexed depositor,
    address indexed recipient,
    uint256 amount,
    bytes32 deliverableHash
);
event ArbiterUpdated(address oldArbiter, address newArbiter);
```

### EscrowContract

Individual escrow instance with built-in dispute resolution.

**State Machine:**
```
CREATED → DISPUTED → COMPLETED/REFUNDED
```

**Fee Structure:**
- `PLATFORM_FEE_BPS`: 100 basis points (1% of escrow amount)
- `DISPUTE_BOND_BPS`: 400 basis points (4% of escrow amount, refundable)

**Core Functions:**

**Creation:**
- `constructor(depositor, recipient, arbiter, token, amount, deliverableHash)`: Initialize escrow
- Automatically funded during creation via factory

**Completion:**
- `completeEscrow()`: Release funds to recipient (depositor only, CREATED state)
- Transfers: escrowAmount to recipient, platformFee to factory, bond back to depositor

**Disputes:**
- `raiseDispute(disputeReasonHash)`: Initiate dispute (either party, CREATED state)
- Requires 4% dispute bond from initiator
- Transitions to DISPUTED state

**Resolution:**
- `resolveDispute(favorDepositor, resolutionHash)`: Arbiter decision (arbiter only, DISPUTED state)
- If `favorDepositor == true`: Depositor receives escrowAmount + disputeBond
- If `favorDepositor == false`: Recipient receives escrowAmount + disputeBond
- Platform fee always collected regardless of outcome

**Events:**
```solidity
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
```

### Hash-Based Document Storage

Contracts store only `keccak256` hashes on-chain. Full documents are stored off-chain in Upstash Redis KV.

**Hashes:**
- `deliverableHash`: Hash of deliverable document (title, description, acceptance criteria)
- `disputeReasonHash`: Hash of dispute reason text
- `resolutionHash`: Hash of arbiter's resolution document

**Pattern:**
1. Frontend creates document → computes `keccak256(JSON.stringify(document))`
2. Submit hash to contract
3. Store full document in KV using hash as key
4. Retrieve document from KV when needed

## Contract Addresses

### Arc Testnet (Chain ID: 5042002)

- **MasterFactory**: `0xe94A1cD5Ca165f4420024De3Fa3ca8940Bc25b64`
- **USDC Token**: `0x3600000000000000000000000000000000000000` (native ERC-20 interface)

## Development Setup

### Prerequisites

- [Foundry](https://book.getfoundry.sh/getting-started/installation) (forge, cast, anvil)
- Git

### Installation

```bash
# Clone the repository
git clone https://github.com/yourusername/sendhaven-arc.git
cd sendhaven-arc

# Install dependencies (OpenZeppelin contracts)
forge install
```

### Environment Configuration

Create a `.env` file in the root directory:

```bash
# Arc Testnet RPC
ARC_TESTNET_RPC_URL=https://rpc.testnet.arc.network

# Private key for deployment (DO NOT commit!)
PRIVATE_KEY=your_private_key_here

# Arc Testnet Explorer API key (for contract verification)
ARCSCAN_API_KEY=your_arcscan_api_key

# USDC token address on Arc Testnet
USDC_ADDRESS=0x3600000000000000000000000000000000000000
```

**Security Note:** Never commit `.env` files or private keys to version control!

## Development Commands

### Building

```bash
# Compile all contracts
forge build

# Compile with optimizer
forge build --optimize --optimizer-runs 200
```

### Testing

```bash
# Run all tests
forge test

# Run tests with verbosity
forge test -vvv

# Run specific test file
forge test --match-path test/SendHaven.t.sol

# Run with gas reporting
forge test --gas-report

# Run tests with coverage
forge coverage
```

### Deployment

#### Deploy to Arc Testnet

```bash
# Load environment variables
source .env

# Deploy MasterFactory
forge script script/DeployFactory.s.sol \
  --rpc-url $ARC_TESTNET_RPC_URL \
  --broadcast \
  --verify

# Deploy MilestoneFactory (experimental)
forge script script/DeployMilestoneFactory.s.sol \
  --rpc-url $ARC_TESTNET_RPC_URL \
  --broadcast \
  --verify
```

**Deployment Output:**
- Contract addresses saved to `broadcast/` directory
- Transaction logs and receipts stored for verification
- Contracts automatically verified on Arcscan if `--verify` flag used

### Contract Verification

```bash
# Verify MasterFactory on Arcscan
forge verify-contract \
  --chain 5042002 \
  --compiler-version v0.8.28 \
  --optimizer-runs 200 \
  <CONTRACT_ADDRESS> \
  src/MasterFactory.sol:MasterFactory \
  --constructor-args $(cast abi-encode "constructor(address)" $USDC_ADDRESS)
```

### Useful Foundry Commands

```bash
# Get gas snapshot
forge snapshot

# Format Solidity code
forge fmt

# Clean build artifacts
forge clean

# Inspect contract storage layout
forge inspect MasterFactory storage-layout

# Get contract size
forge build --sizes
```

## Project Structure

```
sendhaven-arc/
├── src/
│   ├── EscrowContract.sol        # Individual escrow instance
│   ├── MasterFactory.sol         # Factory for creating escrows
│   ├── MilestoneEscrow.sol       # Multi-milestone escrow (experimental)
│   ├── MilestoneFactory.sol      # Factory for milestone escrows
│   └── MockCUSD.sol              # Mock USDC for local testing
├── test/
│   ├── SendHaven.t.sol           # Tests for MasterFactory & EscrowContract
│   └── MilestoneEscrow.t.sol     # Tests for milestone escrows
├── script/
│   ├── DeployFactory.s.sol       # Deployment script for MasterFactory
│   └── DeployMilestoneFactory.s.sol  # Deployment for MilestoneFactory
├── lib/
│   └── openzeppelin-contracts/   # OpenZeppelin dependencies
├── broadcast/                    # Deployment logs and receipts
├── cache/                        # Forge cache
├── out/                          # Compiled artifacts (ABIs, bytecode)
├── foundry.toml                  # Foundry configuration
├── .env                          # Environment variables (DO NOT COMMIT)
└── README.md                     # This file
```

## Testing

### Test Coverage

The test suite covers:

- **EscrowContract lifecycle**: Creation → Completion/Dispute → Resolution
- **Access control**: Only authorized parties can call functions
- **State transitions**: Validates all state machine transitions
- **Fee calculations**: Verifies platform fee and dispute bond math
- **Reentrancy protection**: Tests for reentrancy attacks
- **Edge cases**: Invalid states, zero amounts, unauthorized calls

### Running Specific Tests

```bash
# Test only escrow creation
forge test --match-test testCreateEscrow

# Test dispute resolution
forge test --match-test testDispute

# Test with console logs
forge test -vvvv --match-test testCompleteEscrow
```

## Security Considerations

### Implemented Protections

1. **ReentrancyGuard**: All state-changing functions protected against reentrancy
2. **SafeERC20**: Using OpenZeppelin's SafeERC20 for token transfers
3. **State Machine**: Strict state validation prevents unauthorized transitions
4. **Access Control**: Modifier-based access control (onlyDepositor, onlyArbiter, onlyParties)
5. **Immutable Variables**: Core parameters (depositor, recipient, amounts) are immutable

### Audit Status

**Status**: Not yet audited

This code is in active development. A professional security audit is planned before mainnet deployment.

## Gas Optimization

### Current Optimizations

- Immutable variables for addresses and amounts (cheaper reads)
- Packed structs where possible
- SafeERC20 instead of manual checks
- Minimal storage writes

### Gas Costs (Approximate)

- **Create Escrow**: ~150,000 gas
- **Complete Escrow**: ~60,000 gas
- **Raise Dispute**: ~80,000 gas
- **Resolve Dispute**: ~70,000 gas

**Note**: Arc Testnet uses USDC for gas, making transactions cost-effective.

## Integration with Frontend

The frontend repository (at `../sendhaven`) integrates with these contracts via:

- **ABIs**: Exported from `out/` directory to `apps/web/src/lib/escrow-config.ts`
- **Factory Address**: Stored in `NEXT_PUBLIC_MASTER_FACTORY_ADDRESS_ARC` env variable
- **Events**: Indexed via wagmi's `useContractEvent` and `getLogs`
- **Transactions**: Executed via ethers v6 signers

### Updating ABIs in Frontend

After modifying contracts:

```bash
# 1. Build contracts
forge build

# 2. Copy ABIs to frontend
cp out/MasterFactory.sol/MasterFactory.json ../sendhaven/apps/web/src/lib/abi/
cp out/EscrowContract.sol/EscrowContract.json ../sendhaven/apps/web/src/lib/abi/

# 3. Update escrow-config.ts with new ABI
```

## Roadmap

### Current (V1)
- Basic escrow with dispute resolution
- Factory pattern for deployment
- Hash-based document verification

### Planned (V2)
- Pre-arbitration negotiation period
- Evidence submission system for both parties
- Improved arbiter incentive structure
- Multi-signature arbiter councils

### Future (V3)
- Multi-milestone escrows (currently experimental)
- Recurring payment escrows
- Mainnet deployment (Base, Arbitrum, Ethereum)

## Contributing

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/amazing-feature`)
3. Write tests for new functionality
4. Ensure all tests pass (`forge test`)
5. Commit your changes (`git commit -m 'Add amazing feature'`)
6. Push to the branch (`git push origin feature/amazing-feature`)
7. Open a Pull Request

### Coding Standards

- Follow [Solidity Style Guide](https://docs.soliditylang.org/en/latest/style-guide.html)
- Use NatSpec comments for all public/external functions
- Write comprehensive tests for all new features
- Run `forge fmt` before committing

## Resources

- **Foundry Book**: https://book.getfoundry.sh/
- **OpenZeppelin Contracts**: https://docs.openzeppelin.com/contracts/
- **Arc Testnet Explorer**: https://testnet.arcscan.app
- **Arc Testnet RPC**: https://rpc.testnet.arc.network
- **Frontend Repository**: [sendhaven](https://github.com/Gigentic/sendhaven)

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## Support

For contract-specific questions:
- Open an issue on GitHub
- Review test files for usage examples
- Check deployment scripts for configuration examples
