// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/ZeroVault.sol";
import "./MockERC20.sol";

contract ZeroVaultTest is Test {
    ZeroVault vault;
    MockERC20 usdc;
    MockERC20 usdt;

    // Trinity Validator private keys
    uint256 constant GUARDIAN1_PK = 0x1;
    uint256 constant GUARDIAN2_PK = 0x2;
    uint256 constant GUARDIAN3_PK = 0x3;

    address guardian1;
    address guardian2;
    address guardian3;

    address admin = address(0xAD);
    address alice = address(0xA11CE);
    address bob = address(0xB0B);

    bytes32 constant ZERO_RECIPIENT = bytes32(uint256(0x1234));

    function setUp() public {
        guardian1 = vm.addr(GUARDIAN1_PK);
        guardian2 = vm.addr(GUARDIAN2_PK);
        guardian3 = vm.addr(GUARDIAN3_PK);

        usdc = new MockERC20("USD Coin", "USDC", 6);
        usdt = new MockERC20("Tether USD", "USDT", 6);

        address[] memory tokens = new address[](2);
        tokens[0] = address(usdc);
        tokens[1] = address(usdt);

        vault = new ZeroVault([guardian1, guardian2, guardian3], tokens, admin);
    }

    // --- Helpers ---

    function _depositUSDC(address depositor, uint256 amount) internal {
        usdc.mint(depositor, amount);
        vm.startPrank(depositor);
        usdc.approve(address(vault), amount);
        vault.deposit(address(usdc), amount, ZERO_RECIPIENT);
        vm.stopPrank();
    }

    function _signRelease(
        uint256 pk,
        address token,
        uint256 amount,
        address recipient,
        bytes32 bridgeId
    ) internal view returns (bytes memory) {
        bytes32 structHash = keccak256(abi.encode(
            vault.RELEASE_TYPEHASH(),
            token,
            amount,
            recipient,
            bridgeId
        ));
        bytes32 digest = _hashTypedDataV4(structHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _hashTypedDataV4(bytes32 structHash) internal view returns (bytes32) {
        return keccak256(abi.encodePacked(
            "\x19\x01",
            vault.domainSeparator(),
            structHash
        ));
    }

    // Build sorted guardian signatures
    function _buildSortedSignatures(
        uint256[] memory pks,
        address token,
        uint256 amount,
        address recipient,
        bytes32 bridgeId
    ) internal view returns (bytes memory) {
        uint256 n = pks.length;
        address[] memory addrs = new address[](n);
        for (uint256 i = 0; i < n; i++) {
            addrs[i] = vm.addr(pks[i]);
        }
        // Bubble sort by address ascending
        for (uint256 i = 0; i < n; i++) {
            for (uint256 j = i + 1; j < n; j++) {
                if (addrs[j] < addrs[i]) {
                    (addrs[i], addrs[j]) = (addrs[j], addrs[i]);
                    (pks[i], pks[j]) = (pks[j], pks[i]);
                }
            }
        }
        bytes memory sigs;
        for (uint256 i = 0; i < n; i++) {
            sigs = abi.encodePacked(sigs, _signRelease(pks[i], token, amount, recipient, bridgeId));
        }
        return sigs;
    }

    function _twoOfThreeSignatures(
        address token,
        uint256 amount,
        address recipient,
        bytes32 bridgeId
    ) internal view returns (bytes memory) {
        uint256[] memory pks = new uint256[](2);
        pks[0] = GUARDIAN1_PK;
        pks[1] = GUARDIAN2_PK;
        return _buildSortedSignatures(pks, token, amount, recipient, bridgeId);
    }

    function _threeOfThreeSignatures(
        address token,
        uint256 amount,
        address recipient,
        bytes32 bridgeId
    ) internal view returns (bytes memory) {
        uint256[] memory pks = new uint256[](3);
        pks[0] = GUARDIAN1_PK;
        pks[1] = GUARDIAN2_PK;
        pks[2] = GUARDIAN3_PK;
        return _buildSortedSignatures(pks, token, amount, recipient, bridgeId);
    }

    // ============================================================
    //                       DEPOSIT TESTS
    // ============================================================

    function test_deposit() public {
        _depositUSDC(alice, 1_000_000);

        assertEq(vault.totalLocked(address(usdc)), 1_000_000);
        assertEq(usdc.balanceOf(address(vault)), 1_000_000);
        assertEq(usdc.balanceOf(alice), 0);
    }

    function test_deposit_emits_event() public {
        usdc.mint(alice, 1_000_000);
        vm.startPrank(alice);
        usdc.approve(address(vault), 1_000_000);

        vm.expectEmit(true, true, false, true);
        emit ZeroVault.Deposited(alice, address(usdc), 1_000_000, ZERO_RECIPIENT);

        vault.deposit(address(usdc), 1_000_000, ZERO_RECIPIENT);
        vm.stopPrank();
    }

    function test_deposit_unsupported_token() public {
        MockERC20 fake = new MockERC20("Fake", "FAKE", 18);
        fake.mint(alice, 1000);
        vm.startPrank(alice);
        fake.approve(address(vault), 1000);
        vm.expectRevert("unsupported token");
        vault.deposit(address(fake), 1000, ZERO_RECIPIENT);
        vm.stopPrank();
    }

    function test_deposit_zero_amount() public {
        vm.expectRevert("zero amount");
        vault.deposit(address(usdc), 0, ZERO_RECIPIENT);
    }

    function test_deposit_zero_recipient() public {
        usdc.mint(alice, 1000);
        vm.startPrank(alice);
        usdc.approve(address(vault), 1000);
        vm.expectRevert("zero recipient");
        vault.deposit(address(usdc), 1000, bytes32(0));
        vm.stopPrank();
    }

    function test_deposit_when_paused() public {
        vm.prank(guardian1);
        vault.pause();
        vm.expectRevert("paused");
        vault.deposit(address(usdc), 1000, ZERO_RECIPIENT);
    }

    function test_multiple_deposits() public {
        _depositUSDC(alice, 1_000_000);
        _depositUSDC(bob, 2_000_000);

        assertEq(vault.totalLocked(address(usdc)), 3_000_000);
        assertEq(usdc.balanceOf(address(vault)), 3_000_000);
    }

    function test_deposit_usdt() public {
        usdt.mint(alice, 5_000_000);
        vm.startPrank(alice);
        usdt.approve(address(vault), 5_000_000);
        vault.deposit(address(usdt), 5_000_000, ZERO_RECIPIENT);
        vm.stopPrank();

        assertEq(vault.totalLocked(address(usdt)), 5_000_000);
    }

    // ============================================================
    //                       RELEASE TESTS
    // ============================================================

    function test_release_two_of_three() public {
        _depositUSDC(alice, 10_000_000);

        bytes32 bridgeId = bytes32(uint256(1));
        uint256 amount = 1_000_000;

        bytes memory sigs = _twoOfThreeSignatures(address(usdc), amount, bob, bridgeId);
        vault.release(address(usdc), amount, bob, bridgeId, sigs);

        assertEq(usdc.balanceOf(bob), amount);
        assertEq(vault.totalLocked(address(usdc)), 9_000_000);
        assertTrue(vault.processedBridgeIds(bridgeId));
    }

    function test_release_three_of_three() public {
        _depositUSDC(alice, 10_000_000);

        bytes32 bridgeId = bytes32(uint256(1));
        uint256 amount = 1_000_000;

        bytes memory sigs = _threeOfThreeSignatures(address(usdc), amount, bob, bridgeId);
        vault.release(address(usdc), amount, bob, bridgeId, sigs);

        assertEq(usdc.balanceOf(bob), amount);
    }

    function test_release_emits_event() public {
        _depositUSDC(alice, 10_000_000);

        bytes32 bridgeId = bytes32(uint256(1));
        uint256 amount = 1_000_000;

        bytes memory sigs = _twoOfThreeSignatures(address(usdc), amount, bob, bridgeId);

        vm.expectEmit(true, true, false, true);
        emit ZeroVault.Released(bob, address(usdc), amount, bridgeId);

        vault.release(address(usdc), amount, bob, bridgeId, sigs);
    }

    function test_release_replay_prevented() public {
        _depositUSDC(alice, 10_000_000);

        bytes32 bridgeId = bytes32(uint256(1));
        uint256 amount = 1_000_000;

        bytes memory sigs = _twoOfThreeSignatures(address(usdc), amount, bob, bridgeId);
        vault.release(address(usdc), amount, bob, bridgeId, sigs);

        vm.expectRevert("already processed");
        vault.release(address(usdc), amount, bob, bridgeId, sigs);
    }

    function test_release_one_signature_fails() public {
        _depositUSDC(alice, 10_000_000);

        bytes32 bridgeId = bytes32(uint256(1));
        uint256 amount = 1_000_000;

        uint256[] memory pks = new uint256[](1);
        pks[0] = GUARDIAN1_PK;
        bytes memory sigs = _buildSortedSignatures(pks, address(usdc), amount, bob, bridgeId);

        vm.expectRevert("need at least 2 signatures");
        vault.release(address(usdc), amount, bob, bridgeId, sigs);
    }

    function test_release_non_guardian_fails() public {
        _depositUSDC(alice, 10_000_000);

        bytes32 bridgeId = bytes32(uint256(1));
        uint256 amount = 1_000_000;

        uint256[] memory pks = new uint256[](2);
        pks[0] = GUARDIAN1_PK;
        pks[1] = 0x5; // not a guardian
        bytes memory sigs = _buildSortedSignatures(pks, address(usdc), amount, bob, bridgeId);

        vm.expectRevert("not a guardian");
        vault.release(address(usdc), amount, bob, bridgeId, sigs);
    }

    function test_release_when_paused() public {
        _depositUSDC(alice, 10_000_000);
        vm.prank(guardian1);
        vault.pause();

        bytes32 bridgeId = bytes32(uint256(1));
        bytes memory sigs = _twoOfThreeSignatures(address(usdc), 1_000_000, bob, bridgeId);

        vm.expectRevert("paused");
        vault.release(address(usdc), 1_000_000, bob, bridgeId, sigs);
    }

    function test_release_four_signatures_rejected() public {
        _depositUSDC(alice, 10_000_000);

        bytes32 bridgeId = bytes32(uint256(1));
        uint256 amount = 1_000_000;

        uint256[] memory pks = new uint256[](4);
        pks[0] = GUARDIAN1_PK;
        pks[1] = GUARDIAN2_PK;
        pks[2] = GUARDIAN3_PK;
        pks[3] = 0x5;
        bytes memory sigs = _buildSortedSignatures(pks, address(usdc), amount, bob, bridgeId);

        vm.expectRevert("too many signatures");
        vault.release(address(usdc), amount, bob, bridgeId, sigs);
    }

    // ============================================================
    //                   EIP-712 SIGNATURE TESTS
    // ============================================================

    function test_release_digest_matches() public view {
        bytes32 bridgeId = bytes32(uint256(1));
        uint256 amount = 1_000_000;

        // Compute digest via contract helper
        bytes32 contractDigest = vault.releaseDigest(address(usdc), amount, bob, bridgeId);

        // Compute manually
        bytes32 structHash = keccak256(abi.encode(
            vault.RELEASE_TYPEHASH(),
            address(usdc),
            amount,
            bob,
            bridgeId
        ));
        bytes32 manualDigest = keccak256(abi.encodePacked(
            "\x19\x01",
            vault.domainSeparator(),
            structHash
        ));

        assertEq(contractDigest, manualDigest);
    }

    function test_domain_separator_not_zero() public view {
        assertTrue(vault.domainSeparator() != bytes32(0));
    }

    // ============================================================
    //                   CIRCUIT BREAKER TESTS
    // ============================================================

    function test_normal_tier_allows_under_20_percent() public {
        _depositUSDC(alice, 10_000_000);

        bytes32 bridgeId = bytes32(uint256(1));
        uint256 amount = 1_500_000; // 15%

        bytes memory sigs = _twoOfThreeSignatures(address(usdc), amount, bob, bridgeId);
        vault.release(address(usdc), amount, bob, bridgeId, sigs);

        assertEq(usdc.balanceOf(bob), amount);
    }

    function test_normal_tier_blocks_over_20_percent_with_two_sigs() public {
        _depositUSDC(alice, 10_000_000);

        bytes32 bridgeId = bytes32(uint256(1));
        uint256 amount = 2_100_000; // 21%

        bytes memory sigs = _twoOfThreeSignatures(address(usdc), amount, bob, bridgeId);

        // 21% exceeds normal tier — needs 3-of-3
        vm.expectRevert("elevated tier: need 3-of-3 signatures");
        vault.release(address(usdc), amount, bob, bridgeId, sigs);
    }

    function test_elevated_tier_allows_with_three_sigs() public {
        _depositUSDC(alice, 10_000_000);

        bytes32 bridgeId = bytes32(uint256(1));
        uint256 amount = 3_000_000; // 30%

        // 3-of-3 should work for elevated tier
        bytes memory sigs = _threeOfThreeSignatures(address(usdc), amount, bob, bridgeId);
        vault.release(address(usdc), amount, bob, bridgeId, sigs);

        assertEq(usdc.balanceOf(bob), amount);
    }

    function test_critical_tier_blocks_over_50_percent() public {
        _depositUSDC(alice, 10_000_000);

        // Try to release 51% in one shot — blocked even with 3-of-3
        bytes32 bid1 = bytes32(uint256(1));
        bytes memory sigs1 = _threeOfThreeSignatures(address(usdc), 5_100_000, bob, bid1);

        vm.expectRevert("circuit breaker: exceeds 50% window limit");
        vault.release(address(usdc), 5_100_000, bob, bid1, sigs1);
    }

    function test_critical_tier_cumulative() public {
        _depositUSDC(alice, 10_000_000);

        // Release 45% with 3-of-3 (elevated tier, works)
        bytes32 bid1 = bytes32(uint256(1));
        bytes memory sigs1 = _threeOfThreeSignatures(address(usdc), 4_500_000, bob, bid1);
        vault.release(address(usdc), 4_500_000, bob, bid1, sigs1);

        // After first: totalLocked = 5,500,000, releasedInWindow = 4,500,000
        // 50% of 5,500,000 = 2,750,000. newTotal = 4,500,000 + 1,000,000 = 5,500,000 > 2,750,000
        bytes32 bid2 = bytes32(uint256(2));
        bytes memory sigs2 = _threeOfThreeSignatures(address(usdc), 1_000_000, bob, bid2);

        vm.expectRevert("circuit breaker: exceeds 50% window limit");
        vault.release(address(usdc), 1_000_000, bob, bid2, sigs2);
    }

    function test_circuit_breaker_resets_after_window() public {
        _depositUSDC(alice, 10_000_000);

        bytes32 bid1 = bytes32(uint256(1));
        bytes memory sigs1 = _twoOfThreeSignatures(address(usdc), 1_500_000, bob, bid1);
        vault.release(address(usdc), 1_500_000, bob, bid1, sigs1);

        vm.warp(block.timestamp + 25 hours);

        bytes32 bid2 = bytes32(uint256(2));
        bytes memory sigs2 = _twoOfThreeSignatures(address(usdc), 1_500_000, bob, bid2);
        vault.release(address(usdc), 1_500_000, bob, bid2, sigs2);

        assertEq(usdc.balanceOf(bob), 3_000_000);
    }

    function test_elevated_cumulative() public {
        _depositUSDC(alice, 10_000_000);

        // First release 15% (normal, 2-of-3)
        bytes32 bid1 = bytes32(uint256(1));
        bytes memory sigs1 = _twoOfThreeSignatures(address(usdc), 1_500_000, bob, bid1);
        vault.release(address(usdc), 1_500_000, bob, bid1, sigs1);

        // Second release 10% (cumulative 25% > 20%) — needs 3-of-3
        bytes32 bid2 = bytes32(uint256(2));
        // After first: totalLocked = 8,500,000. 20% of 8,500,000 = 1,700,000.
        // releasedInWindow = 1,500,000 + 1_000_000 = 2,500,000 > 1,700,000
        bytes memory sigs2 = _twoOfThreeSignatures(address(usdc), 1_000_000, bob, bid2);

        vm.expectRevert("elevated tier: need 3-of-3 signatures");
        vault.release(address(usdc), 1_000_000, bob, bid2, sigs2);

        // Should work with 3-of-3
        bytes memory sigs3 = _threeOfThreeSignatures(address(usdc), 1_000_000, bob, bid2);
        vault.release(address(usdc), 1_000_000, bob, bid2, sigs3);

        assertEq(usdc.balanceOf(bob), 2_500_000);
    }

    // ============================================================
    //                   ASYMMETRIC PAUSE TESTS
    // ============================================================

    function test_any_guardian_can_pause() public {
        vm.prank(guardian1);
        vault.pause();
        assertTrue(vault.paused());

        // Unpause for next test
        vm.prank(admin);
        vault.unpause();

        vm.prank(guardian2);
        vault.pause();
        assertTrue(vault.paused());

        vm.prank(admin);
        vault.unpause();

        vm.prank(guardian3);
        vault.pause();
        assertTrue(vault.paused());
    }

    function test_only_admin_can_unpause() public {
        vm.prank(guardian1);
        vault.pause();

        // Guardian cannot unpause
        vm.prank(guardian1);
        vm.expectRevert();
        vault.unpause();

        // Random address cannot unpause
        vm.prank(alice);
        vm.expectRevert();
        vault.unpause();

        // Admin can unpause
        vm.prank(admin);
        vault.unpause();
        assertFalse(vault.paused());
    }

    function test_non_guardian_cannot_pause() public {
        vm.prank(alice);
        vm.expectRevert();
        vault.pause();
    }

    function test_pause_emits_event() public {
        vm.expectEmit(true, false, false, false);
        emit ZeroVault.VaultPaused(guardian1);

        vm.prank(guardian1);
        vault.pause();
    }

    function test_unpause_emits_event() public {
        vm.prank(guardian1);
        vault.pause();

        vm.expectEmit(true, false, false, false);
        emit ZeroVault.VaultUnpaused(admin);

        vm.prank(admin);
        vault.unpause();
    }

    // ============================================================
    //                TIMELOCKED GUARDIAN ROTATION
    // ============================================================

    function test_queue_rotation() public {
        address newGuardian = address(0x999);
        vm.prank(admin);
        vault.queueGuardianRotation(2, newGuardian);

        (address pending, uint256 executeAfter) = vault.pendingRotations(2);
        assertEq(pending, newGuardian);
        assertEq(executeAfter, block.timestamp + 48 hours);
    }

    function test_execute_rotation_after_delay() public {
        address newGuardian = address(0x999);

        vm.prank(admin);
        vault.queueGuardianRotation(2, newGuardian);

        // Cannot execute before delay
        vm.prank(admin);
        vm.expectRevert("rotation not ready");
        vault.executeGuardianRotation(2);

        // Fast forward past delay
        vm.warp(block.timestamp + 48 hours);

        vm.prank(admin);
        vault.executeGuardianRotation(2);

        assertTrue(vault.isGuardian(newGuardian));
        assertFalse(vault.isGuardian(guardian3));
        assertEq(vault.guardians(2), newGuardian);

        // Pending should be cleared
        (address pending, uint256 executeAfter) = vault.pendingRotations(2);
        assertEq(pending, address(0));
        assertEq(executeAfter, 0);
    }

    function test_rotation_non_admin_reverts() public {
        vm.prank(alice);
        vm.expectRevert();
        vault.queueGuardianRotation(0, address(0x999));
    }

    function test_rotation_duplicate_guardian_reverts() public {
        vm.prank(admin);
        vm.expectRevert("already a guardian");
        vault.queueGuardianRotation(2, guardian1);
    }

    function test_rotation_invalid_index_reverts() public {
        vm.prank(admin);
        vm.expectRevert("invalid index");
        vault.queueGuardianRotation(3, address(0x999));
    }

    function test_cancel_rotation() public {
        address newGuardian = address(0x999);

        vm.prank(admin);
        vault.queueGuardianRotation(2, newGuardian);

        vm.prank(admin);
        vault.cancelGuardianRotation(2);

        (address pending, uint256 executeAfter) = vault.pendingRotations(2);
        assertEq(pending, address(0));
        assertEq(executeAfter, 0);
    }

    function test_double_queue_reverts() public {
        vm.prank(admin);
        vault.queueGuardianRotation(2, address(0x999));

        vm.prank(admin);
        vm.expectRevert("rotation already pending");
        vault.queueGuardianRotation(2, address(0x888));
    }

    function test_rotated_guardian_gets_pauser_role() public {
        address newGuardian = address(0x999);

        vm.prank(admin);
        vault.queueGuardianRotation(2, newGuardian);
        vm.warp(block.timestamp + 48 hours);
        vm.prank(admin);
        vault.executeGuardianRotation(2);

        // New guardian can pause
        vm.prank(newGuardian);
        vault.pause();
        assertTrue(vault.paused());

        // Old guardian cannot pause
        vm.prank(admin);
        vault.unpause();

        vm.prank(guardian3);
        vm.expectRevert();
        vault.pause();
    }

    function test_release_after_rotation() public {
        _depositUSDC(alice, 10_000_000);

        // Rotate guardian3 out
        uint256 newGuardianPk = 0x4;
        address newGuardian = vm.addr(newGuardianPk);

        vm.prank(admin);
        vault.queueGuardianRotation(2, newGuardian);
        vm.warp(block.timestamp + 48 hours);
        vm.prank(admin);
        vault.executeGuardianRotation(2);

        // Sign with guardian1 + new guardian (should work)
        bytes32 bridgeId = bytes32(uint256(1));
        uint256 amount = 1_000_000;

        uint256[] memory pks = new uint256[](2);
        pks[0] = GUARDIAN1_PK;
        pks[1] = newGuardianPk;
        bytes memory sigs = _buildSortedSignatures(pks, address(usdc), amount, bob, bridgeId);
        vault.release(address(usdc), amount, bob, bridgeId, sigs);

        assertEq(usdc.balanceOf(bob), amount);
    }

    // ============================================================
    //                     TOKEN MANAGEMENT
    // ============================================================

    function test_add_remove_token() public {
        MockERC20 dai = new MockERC20("Dai", "DAI", 18);

        vm.prank(admin);
        vault.addToken(address(dai));
        assertTrue(vault.supportedTokens(address(dai)));

        vm.prank(admin);
        vault.removeToken(address(dai));
        assertFalse(vault.supportedTokens(address(dai)));
    }

    function test_add_token_non_admin_reverts() public {
        vm.prank(alice);
        vm.expectRevert();
        vault.addToken(address(0x123));
    }

    // ============================================================
    //                    ACCESS CONTROL TESTS
    // ============================================================

    function test_admin_has_default_admin_role() public view {
        assertTrue(vault.hasRole(vault.DEFAULT_ADMIN_ROLE(), admin));
    }

    function test_guardians_have_pauser_role() public view {
        assertTrue(vault.hasRole(vault.PAUSER_ROLE(), guardian1));
        assertTrue(vault.hasRole(vault.PAUSER_ROLE(), guardian2));
        assertTrue(vault.hasRole(vault.PAUSER_ROLE(), guardian3));
    }

    function test_guardian_check() public view {
        assertTrue(vault.isGuardian(guardian1));
        assertTrue(vault.isGuardian(guardian2));
        assertTrue(vault.isGuardian(guardian3));
        assertFalse(vault.isGuardian(alice));
    }

    function test_trinity_count_and_threshold() public view {
        assertEq(vault.trinityCount(), 3);
        assertEq(vault.quorumThreshold(), 2);
    }

    // ============================================================
    //                   CONSTRUCTOR VALIDATION
    // ============================================================

    function test_constructor_zero_admin_reverts() public {
        address[] memory tokens = new address[](0);
        vm.expectRevert("zero admin");
        new ZeroVault([guardian1, guardian2, guardian3], tokens, address(0));
    }

    function test_constructor_zero_guardian_reverts() public {
        address[] memory tokens = new address[](0);
        vm.expectRevert("zero address");
        new ZeroVault([address(0), guardian2, guardian3], tokens, admin);
    }

    function test_constructor_duplicate_guardian_reverts() public {
        address[] memory tokens = new address[](0);
        vm.expectRevert("duplicate guardian");
        new ZeroVault([guardian1, guardian1, guardian3], tokens, admin);
    }
}
