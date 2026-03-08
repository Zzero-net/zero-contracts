// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "../src/ZeroTimelock.sol";

/// @notice Deploy ZeroTimelock for ZeroVault admin migration.
///
/// After deployment:
///   1. Call vault.grantRole(DEFAULT_ADMIN_ROLE, timelockAddress) from current admin
///   2. Call vault.revokeRole(DEFAULT_ADMIN_ROLE, currentAdmin) via timelock proposal
///      (or current admin renounces after granting to timelock)
///
/// Usage:
///   # Base mainnet (24h delay)
///   DELAY=86400 forge script script/DeployTimelock.s.sol --rpc-url $BASE_RPC --broadcast --verify
///
///   # Testnet (0 delay for testing)
///   DELAY=0 forge script script/DeployTimelock.s.sol --rpc-url $BASE_SEPOLIA_RPC --broadcast --verify
///
/// Environment variables:
///   DEPLOYER_PRIVATE_KEY  — deployer EOA
///   GUARDIAN_1            — Trinity Validator 1 (0x4dBF...4Fe)
///   GUARDIAN_2            — Trinity Validator 2 (0x4bC7...9d9)
///   GUARDIAN_3            — Trinity Validator 3 (0x0654...2a9)
///   DELAY                 — Timelock delay in seconds (86400 = 24h)
contract DeployTimelock is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address guardian1 = vm.envAddress("GUARDIAN_1");
        address guardian2 = vm.envAddress("GUARDIAN_2");
        address guardian3 = vm.envAddress("GUARDIAN_3");
        uint256 delaySeconds = vm.envUint("DELAY");

        require(guardian1 != address(0), "GUARDIAN_1 not set");
        require(guardian2 != address(0), "GUARDIAN_2 not set");
        require(guardian3 != address(0), "GUARDIAN_3 not set");

        vm.startBroadcast(deployerKey);

        ZeroTimelock timelock = new ZeroTimelock(
            [guardian1, guardian2, guardian3],
            delaySeconds
        );

        vm.stopBroadcast();

        console.log("ZeroTimelock deployed at:", address(timelock));
        console.log("  Guardian 1:", guardian1);
        console.log("  Guardian 2:", guardian2);
        console.log("  Guardian 3:", guardian3);
        console.log("  Delay:", delaySeconds, "seconds");
        console.log("  Chain ID:", block.chainid);
        console.log("");
        console.log("Next steps:");
        console.log("  1. From current admin EOA, call:");
        console.log("     vault.grantRole(DEFAULT_ADMIN_ROLE, timelockAddress)");
        console.log("  2. From current admin EOA, call:");
        console.log("     vault.renounceRole(DEFAULT_ADMIN_ROLE, currentAdmin)");
    }
}
