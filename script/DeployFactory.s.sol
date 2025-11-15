// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Script.sol";
import "../src/MasterFactory.sol";

/**
 * @title DeployFactory
 * @dev Deployment script for SendHaven MasterFactory on Arc blockchain
 *
 * Usage:
 *   forge script script/DeployFactory.s.sol:DeployFactory \
 *     --rpc-url $ARC_TESTNET_RPC_URL \
 *     --private-key $PRIVATE_KEY \
 *     --broadcast
 */
contract DeployFactory is Script {
    function run() external {
        // Load environment variables
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address usdcAddress = vm.envAddress("USDC_ADDRESS");

        console.log("Deploying SendHaven MasterFactory...");
        console.log("Deployer:", vm.addr(deployerPrivateKey));
        console.log("USDC Address:", usdcAddress);

        // Start broadcasting transactions
        vm.startBroadcast(deployerPrivateKey);

        // Deploy MasterFactory with Arc USDC address
        MasterFactory factory = new MasterFactory(usdcAddress);

        vm.stopBroadcast();

        // Log deployment info
        console.log("");
        console.log("====================================");
        console.log("SendHaven MasterFactory Deployed!");
        console.log("====================================");
        console.log("Factory Address:", address(factory));
        console.log("Admin:", factory.admin());
        console.log("Arbiter:", factory.arbiter());
        console.log("USDC Token:", factory.cUSDAddress());
        console.log("====================================");
        console.log("");
        console.log("Save this to .env:");
        console.log('FACTORY_ADDRESS="%s"', address(factory));
        console.log("");
        console.log("Verify on Arc Explorer:");
        console.log("https://testnet.arcscan.app/address/%s", address(factory));
    }
}
