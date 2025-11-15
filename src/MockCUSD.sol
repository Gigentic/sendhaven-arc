// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @title MockCUSD
 * @dev Mock stablecoin token for local testing purposes ONLY
 * @notice NOT used on Arc Testnet - Arc uses native USDC at 0x3600000000000000000000000000000000000000
 */
contract MockCUSD is ERC20 {
    constructor() ERC20("Mock USD", "mUSD") {
        // Mint initial supply to deployer for testing
        _mint(msg.sender, 1000000 * 10**decimals());
    }

    /**
     * @dev Mint tokens to any address (for testing)
     */
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    /**
     * @dev Override decimals to match standard USDC (6 decimals)
     */
    function decimals() public pure override returns (uint8) {
        return 6;
    }
}
