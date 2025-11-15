// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Script.sol";
import "../src/MilestoneFactory.sol";

/**
 * @title DeployMilestoneFactory
 * @dev Deployment script for SendHaven MilestoneFactory on Arc blockchain
 *
 * This deploys the new milestone-based escrow system with:
 * - EIP-1167 minimal proxy pattern for gas savings (~90%)
 * - Deadline-based refunds with 3-day grace period
 * - Per-milestone escrows instead of job-level escrows
 *
 * Usage:
 *   source .env
 *   forge script script/DeployMilestoneFactory.s.sol:DeployMilestoneFactory \
 *     --rpc-url $ARC_TESTNET_RPC_URL \
 *     --broadcast \
 *     --verify
 */
contract DeployMilestoneFactory is Script {
    function run() external {
        // Load environment variables
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address usdcAddress = vm.envAddress("USDC_ADDRESS");

        console.log("Deploying SendHaven MilestoneFactory (with EIP-1167 Proxies)...");
        console.log("Deployer:", vm.addr(deployerPrivateKey));
        console.log("USDC Address:", usdcAddress);

        // Start broadcasting transactions
        vm.startBroadcast(deployerPrivateKey);

        // Deploy MilestoneFactory
        // Note: This will also deploy the implementation contract internally
        MilestoneFactory factory = new MilestoneFactory(usdcAddress);

        vm.stopBroadcast();

        // Get implementation address
        address implementationAddr = factory.getImplementation();

        // Log deployment info
        console.log("");
        console.log("============================================");
        console.log("SendHaven MilestoneFactory Deployed!");
        console.log("============================================");
        console.log("Factory Address:", address(factory));
        console.log("Implementation Address:", implementationAddr);
        console.log("Admin:", factory.admin());
        console.log("Arbiter:", factory.arbiter());
        console.log("Supported Token (USDC):", usdcAddress);
        console.log("============================================");
        console.log("");
        console.log("Save these to .env:");
        console.log('NEXT_PUBLIC_MILESTONE_FACTORY_ADDRESS_ARC="%s"', address(factory));
        console.log('MILESTONE_IMPLEMENTATION_ADDRESS="%s"', implementationAddr);
        console.log("");
        console.log("Verify on Arc Explorer:");
        console.log("Factory: https://testnet.arcscan.app/address/%s", address(factory));
        console.log("Implementation: https://testnet.arcscan.app/address/%s", implementationAddr);
        console.log("");
        console.log("Gas Savings:");
        console.log("- Traditional deployment: ~2,000,000 gas per escrow");
        console.log("- With EIP-1167 proxy: ~200,000 gas per escrow");
        console.log("- Savings: ~90%% per milestone creation");
    }
}
