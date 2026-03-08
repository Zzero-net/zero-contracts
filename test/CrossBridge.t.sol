// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/ZeroVault.sol";
import "./MockERC20.sol";

/// @notice Cross-bridge integration test.
/// Verifies that ECDSA signatures produced by the Rust zero-bridge crate's
/// EIP-712 signer are accepted by the Solidity ZeroVault contract.
///
/// We simulate what the Rust bridge service does:
///   1. Compute EIP-712 domain separator (must match contract)
///   2. Compute Release struct hash
///   3. Compute digest = keccak256("\x19\x01" || domainSeparator || structHash)
///   4. Sign with ECDSA (secp256k1)
///   5. Submit to vault.release()
contract CrossBridgeTest is Test {
    ZeroVault vault;
    MockERC20 usdc;

    // Use known private keys (same approach as Rust tests)
    uint256 constant KEY1 = 0x01;
    uint256 constant KEY2 = 0x02;
    uint256 constant KEY3 = 0x03;

    address guardian1;
    address guardian2;
    address guardian3;
    address admin = address(0xAD);
    address alice = address(0xA11CE);
    address bob = address(0xB0B);

    bytes32 constant ZERO_RECIPIENT = bytes32(uint256(0x1234));

    function setUp() public {
        guardian1 = vm.addr(KEY1);
        guardian2 = vm.addr(KEY2);
        guardian3 = vm.addr(KEY3);

        usdc = new MockERC20("USD Coin", "USDC", 6);

        address[] memory tokens = new address[](1);
        tokens[0] = address(usdc);

        vault = new ZeroVault([guardian1, guardian2, guardian3], tokens, admin);

        // Fund vault
        usdc.mint(alice, 10_000_000);
        vm.startPrank(alice);
        usdc.approve(address(vault), 10_000_000);
        vault.deposit(address(usdc), 10_000_000, ZERO_RECIPIENT);
        vm.stopPrank();
    }

    /// @notice Manually construct the EIP-712 digest exactly as the Rust code does,
    /// then sign it and verify the vault accepts it.
    function test_manual_eip712_matches_contract() public {
        address token = address(usdc);
        uint256 amount = 1_000_000;
        address recipient = bob;
        bytes32 bridgeId = bytes32(uint256(42));

        // Step 1: Compute struct hash (must match Rust's release_struct_hash)
        bytes32 releaseTypehash = vault.RELEASE_TYPEHASH();
        bytes32 structHash = keccak256(abi.encode(
            releaseTypehash,
            token,
            amount,
            recipient,
            bridgeId
        ));

        // Step 2: Compute full EIP-712 digest
        bytes32 domainSep = vault.domainSeparator();
        bytes32 digest = keccak256(abi.encodePacked(
            "\x19\x01",
            domainSep,
            structHash
        ));

        // Step 3: Verify the contract's helper produces the same digest
        bytes32 contractDigest = vault.releaseDigest(token, amount, recipient, bridgeId);
        assertEq(digest, contractDigest, "manual digest must match contract helper");

        // Step 4: Sign with two guardian keys (simulating Rust signer)
        bytes memory sigs = _signDigest2of3(digest);

        // Step 5: Submit to vault — this is the critical test
        vault.release(token, amount, recipient, bridgeId, sigs);

        assertEq(usdc.balanceOf(bob), amount, "bob should have received tokens");
    }

    /// @notice Verify the RELEASE_TYPEHASH constant matches the expected keccak256
    function test_release_typehash() public view {
        bytes32 expected = keccak256("Release(address token,uint256 amount,address recipient,bytes32 bridgeId)");
        assertEq(vault.RELEASE_TYPEHASH(), expected);
    }

    /// @notice Verify domain separator components
    function test_domain_separator_components() public {
        // The domain separator should incorporate chain ID and contract address
        bytes32 ds = vault.domainSeparator();
        assertTrue(ds != bytes32(0), "domain separator should be non-zero");

        // Deploying a second vault should give a different domain separator
        // (different address, same chain)
        address[] memory tokens = new address[](0);
        ZeroVault vault2 = new ZeroVault([guardian1, guardian2, guardian3], tokens, admin);
        assertTrue(vault2.domainSeparator() != ds, "different vault address = different domain");
    }

    /// @notice Test that the Rust-style signing flow works end-to-end
    /// with all three signers (3-of-3 for elevated tier)
    function test_three_of_three_eip712() public {
        address token = address(usdc);
        uint256 amount = 3_000_000; // 30% — elevated tier, needs 3-of-3
        bytes32 bridgeId = bytes32(uint256(99));

        bytes32 digest = vault.releaseDigest(token, amount, bob, bridgeId);

        // Use helper to build sorted 3-of-3 signatures
        uint256[] memory pks = new uint256[](3);
        pks[0] = KEY1;
        pks[1] = KEY2;
        pks[2] = KEY3;
        bytes memory sigs = _buildSortedSigs(pks, digest);

        vault.release(token, amount, bob, bridgeId, sigs);
        assertEq(usdc.balanceOf(bob), amount);
    }

    /// @notice Verify that a signature over a different digest is rejected
    function test_wrong_digest_rejected() public {
        address token = address(usdc);
        uint256 amount = 1_000_000;
        address recipient = bob;
        bytes32 bridgeId = bytes32(uint256(1));

        // Sign a DIFFERENT set of params
        bytes32 wrongDigest = vault.releaseDigest(token, 999_999, recipient, bridgeId);
        bytes memory sigs = _signDigest2of3(wrongDigest);

        // Submit with the CORRECT params — signature won't match
        vm.expectRevert("not a guardian");
        vault.release(token, amount, recipient, bridgeId, sigs);
    }

    // --- Helpers ---

    function _buildSortedSigs(uint256[] memory pks, bytes32 digest) internal pure returns (bytes memory) {
        uint256 n = pks.length;
        address[] memory addrs = new address[](n);
        bytes[] memory sigs = new bytes[](n);

        for (uint256 i = 0; i < n; i++) {
            addrs[i] = vm.addr(pks[i]);
            (uint8 v, bytes32 r, bytes32 s) = vm.sign(pks[i], digest);
            sigs[i] = abi.encodePacked(r, s, v);
        }

        // Bubble sort by address ascending
        for (uint256 i = 0; i < n; i++) {
            for (uint256 j = i + 1; j < n; j++) {
                if (addrs[j] < addrs[i]) {
                    (addrs[i], addrs[j]) = (addrs[j], addrs[i]);
                    (sigs[i], sigs[j]) = (sigs[j], sigs[i]);
                }
            }
        }

        bytes memory result;
        for (uint256 i = 0; i < n; i++) {
            result = abi.encodePacked(result, sigs[i]);
        }
        return result;
    }

    function _signDigest2of3(bytes32 digest) internal pure returns (bytes memory) {
        uint256[] memory pks = new uint256[](2);
        pks[0] = KEY1;
        pks[1] = KEY2;
        return _buildSortedSigs(pks, digest);
    }
}
