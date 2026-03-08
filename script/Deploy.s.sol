// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "../src/ZeroVault.sol";

/// @notice Deploy ZeroVault to Base (USDC) or Arbitrum (USDT).
///
/// Usage:
///   # Base Sepolia (USDC)
///   forge script script/Deploy.s.sol --rpc-url $BASE_SEPOLIA_RPC --broadcast --verify
///
///   # Arbitrum Sepolia (USDT)
///   forge script script/Deploy.s.sol --rpc-url $ARBITRUM_SEPOLIA_RPC --broadcast --verify
///
/// Environment variables:
///   DEPLOYER_PRIVATE_KEY  — deployer EOA (also initial admin until transferred)
///   GUARDIAN_1            — Trinity Validator 1 address
///   GUARDIAN_2            — Trinity Validator 2 address
///   GUARDIAN_3            — Trinity Validator 3 address
///   TOKEN_ADDRESS         — USDC or USDT address on the target chain
///   ADMIN_ADDRESS         — multisig or TimelockController that will be admin
contract DeployVault is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address guardian1 = vm.envAddress("GUARDIAN_1");
        address guardian2 = vm.envAddress("GUARDIAN_2");
        address guardian3 = vm.envAddress("GUARDIAN_3");
        address token = vm.envAddress("TOKEN_ADDRESS");
        address admin = vm.envAddress("ADMIN_ADDRESS");

        require(guardian1 != address(0), "GUARDIAN_1 not set");
        require(guardian2 != address(0), "GUARDIAN_2 not set");
        require(guardian3 != address(0), "GUARDIAN_3 not set");
        require(token != address(0), "TOKEN_ADDRESS not set");
        require(admin != address(0), "ADMIN_ADDRESS not set");

        address[] memory tokens = new address[](1);
        tokens[0] = token;

        vm.startBroadcast(deployerKey);

        ZeroVault vault = new ZeroVault(
            [guardian1, guardian2, guardian3],
            tokens,
            admin
        );

        vm.stopBroadcast();

        // Log deployment info
        console.log("ZeroVault deployed at:", address(vault));
        console.log("  Admin:", admin);
        console.log("  Guardian 1:", guardian1);
        console.log("  Guardian 2:", guardian2);
        console.log("  Guardian 3:", guardian3);
        console.log("  Token:", token);
        console.log("  Chain ID:", block.chainid);
        console.log("  Domain Separator:", vm.toString(vault.domainSeparator()));
    }
}
