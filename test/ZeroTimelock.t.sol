// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/ZeroTimelock.sol";
import "../src/ZeroVault.sol";
import "./MockERC20.sol";

contract ZeroTimelockTest is Test {
    ZeroTimelock timelock;
    ZeroVault vault;
    MockERC20 usdc;

    address guardian1 = address(0x1001);
    address guardian2 = address(0x2002);
    address guardian3 = address(0x3003);

    address alice = address(0xA11CE);

    uint256 constant DELAY = 24 hours;

    function setUp() public {
        // Deploy timelock with 24h delay
        timelock = new ZeroTimelock([guardian1, guardian2, guardian3], DELAY);

        // Deploy vault with timelock as admin
        usdc = new MockERC20("USD Coin", "USDC", 6);
        address[] memory tokens = new address[](1);
        tokens[0] = address(usdc);
        vault = new ZeroVault([guardian1, guardian2, guardian3], tokens, address(timelock));
    }

    // ============================================================
    //                     CONSTRUCTOR TESTS
    // ============================================================

    function test_constructor_sets_guardians() public view {
        assertEq(timelock.guardians(0), guardian1);
        assertEq(timelock.guardians(1), guardian2);
        assertEq(timelock.guardians(2), guardian3);
        assertTrue(timelock.isGuardian(guardian1));
        assertTrue(timelock.isGuardian(guardian2));
        assertTrue(timelock.isGuardian(guardian3));
    }

    function test_constructor_sets_delay() public view {
        assertEq(timelock.delay(), DELAY);
    }

    function test_constructor_zero_delay() public {
        ZeroTimelock tl = new ZeroTimelock([guardian1, guardian2, guardian3], 0);
        assertEq(tl.delay(), 0);
    }

    function test_constructor_zero_address_reverts() public {
        vm.expectRevert("zero address");
        new ZeroTimelock([address(0), guardian2, guardian3], DELAY);
    }

    function test_constructor_duplicate_guardian_reverts() public {
        vm.expectRevert("duplicate guardian");
        new ZeroTimelock([guardian1, guardian1, guardian3], DELAY);
    }

    function test_constructor_delay_too_long_reverts() public {
        vm.expectRevert("delay too long");
        new ZeroTimelock([guardian1, guardian2, guardian3], 31 days);
    }

    function test_constants() public view {
        assertEq(timelock.GUARDIAN_COUNT(), 3);
        assertEq(timelock.THRESHOLD(), 2);
        assertEq(timelock.MAX_DELAY(), 30 days);
        assertEq(timelock.GRACE_PERIOD(), 14 days);
    }

    // ============================================================
    //                      PROPOSE TESTS
    // ============================================================

    function test_propose() public {
        bytes memory data = abi.encodeCall(ZeroVault.unpause, ());

        vm.prank(guardian1);
        bytes32 id = timelock.propose(address(vault), 0, data);

        (
            address proposer,
            address target,
            uint256 value,
            bytes memory retData,
            uint256 executeAfter,
            bool executed,
            bool cancelled,
            uint256 confirmCount
        ) = timelock.getProposal(id);

        assertEq(proposer, guardian1);
        assertEq(target, address(vault));
        assertEq(value, 0);
        assertEq(keccak256(retData), keccak256(data));
        assertEq(executeAfter, block.timestamp + DELAY);
        assertFalse(executed);
        assertFalse(cancelled);
        assertEq(confirmCount, 1); // proposer auto-confirms
    }

    function test_propose_non_guardian_reverts() public {
        bytes memory data = abi.encodeCall(ZeroVault.unpause, ());
        vm.prank(alice);
        vm.expectRevert("not guardian");
        timelock.propose(address(vault), 0, data);
    }

    function test_propose_auto_confirms_proposer() public {
        bytes memory data = abi.encodeCall(ZeroVault.unpause, ());

        vm.prank(guardian1);
        bytes32 id = timelock.propose(address(vault), 0, data);

        assertTrue(timelock.hasConfirmed(id, guardian1));
        assertFalse(timelock.hasConfirmed(id, guardian2));
    }

    function test_propose_emits_events() public {
        bytes memory data = abi.encodeCall(ZeroVault.unpause, ());

        vm.prank(guardian1);
        vm.expectEmit(false, true, false, false);
        emit ZeroTimelock.ProposalCreated(bytes32(0), guardian1, address(vault), 0, data, 0);
        timelock.propose(address(vault), 0, data);
    }

    // ============================================================
    //                     CONFIRM TESTS
    // ============================================================

    function test_confirm() public {
        bytes memory data = abi.encodeCall(ZeroVault.unpause, ());
        vm.prank(guardian1);
        bytes32 id = timelock.propose(address(vault), 0, data);

        vm.prank(guardian2);
        timelock.confirm(id);

        assertTrue(timelock.hasConfirmed(id, guardian2));
        (,,,,,,, uint256 confirmCount) = timelock.getProposal(id);
        assertEq(confirmCount, 2);
    }

    function test_confirm_non_guardian_reverts() public {
        bytes memory data = abi.encodeCall(ZeroVault.unpause, ());
        vm.prank(guardian1);
        bytes32 id = timelock.propose(address(vault), 0, data);

        vm.prank(alice);
        vm.expectRevert("not guardian");
        timelock.confirm(id);
    }

    function test_confirm_double_reverts() public {
        bytes memory data = abi.encodeCall(ZeroVault.unpause, ());
        vm.prank(guardian1);
        bytes32 id = timelock.propose(address(vault), 0, data);

        vm.prank(guardian1);
        vm.expectRevert("already confirmed");
        timelock.confirm(id);
    }

    function test_confirm_nonexistent_reverts() public {
        vm.prank(guardian1);
        vm.expectRevert("proposal not found");
        timelock.confirm(bytes32(uint256(999)));
    }

    function test_confirm_executed_reverts() public {
        // Pause vault first, then propose unpause
        vm.prank(guardian1);
        vault.pause();

        bytes memory data = abi.encodeCall(ZeroVault.unpause, ());
        vm.prank(guardian1);
        bytes32 id = timelock.propose(address(vault), 0, data);
        vm.prank(guardian2);
        timelock.confirm(id);
        vm.warp(block.timestamp + DELAY);
        timelock.execute(id);

        vm.prank(guardian3);
        vm.expectRevert("already executed");
        timelock.confirm(id);
    }

    function test_confirm_cancelled_reverts() public {
        bytes memory data = abi.encodeCall(ZeroVault.unpause, ());
        vm.prank(guardian1);
        bytes32 id = timelock.propose(address(vault), 0, data);

        vm.prank(guardian1);
        timelock.cancel(id);

        vm.prank(guardian2);
        vm.expectRevert("already cancelled");
        timelock.confirm(id);
    }

    function test_confirm_emits_event() public {
        bytes memory data = abi.encodeCall(ZeroVault.unpause, ());
        vm.prank(guardian1);
        bytes32 id = timelock.propose(address(vault), 0, data);

        vm.expectEmit(true, true, false, false);
        emit ZeroTimelock.ProposalConfirmed(id, guardian2);

        vm.prank(guardian2);
        timelock.confirm(id);
    }

    // ============================================================
    //                     EXECUTE TESTS
    // ============================================================

    function test_execute_unpause() public {
        // Pause the vault
        vm.prank(guardian1);
        vault.pause();
        assertTrue(vault.paused());

        // Propose unpause via timelock
        bytes memory data = abi.encodeCall(ZeroVault.unpause, ());
        vm.prank(guardian1);
        bytes32 id = timelock.propose(address(vault), 0, data);

        vm.prank(guardian2);
        timelock.confirm(id);

        // Cannot execute before delay
        vm.expectRevert("delay not elapsed");
        timelock.execute(id);

        // Warp past delay
        vm.warp(block.timestamp + DELAY);

        // Anyone can execute
        vm.prank(alice);
        timelock.execute(id);

        assertFalse(vault.paused());
    }

    function test_execute_add_token() public {
        MockERC20 dai = new MockERC20("Dai", "DAI", 18);

        bytes memory data = abi.encodeCall(ZeroVault.addToken, (address(dai)));
        vm.prank(guardian1);
        bytes32 id = timelock.propose(address(vault), 0, data);

        vm.prank(guardian2);
        timelock.confirm(id);

        vm.warp(block.timestamp + DELAY);
        timelock.execute(id);

        assertTrue(vault.supportedTokens(address(dai)));
    }

    function test_execute_remove_token() public {
        bytes memory data = abi.encodeCall(ZeroVault.removeToken, (address(usdc)));
        vm.prank(guardian1);
        bytes32 id = timelock.propose(address(vault), 0, data);

        vm.prank(guardian3);
        timelock.confirm(id);

        vm.warp(block.timestamp + DELAY);
        timelock.execute(id);

        assertFalse(vault.supportedTokens(address(usdc)));
    }

    function test_execute_queue_guardian_rotation() public {
        address newGuardian = address(0x9999);

        bytes memory data = abi.encodeCall(ZeroVault.queueGuardianRotation, (2, newGuardian));
        vm.prank(guardian1);
        bytes32 id = timelock.propose(address(vault), 0, data);

        vm.prank(guardian2);
        timelock.confirm(id);

        vm.warp(block.timestamp + DELAY);
        timelock.execute(id);

        (address pending, uint256 executeAfter) = vault.pendingRotations(2);
        assertEq(pending, newGuardian);
        assertTrue(executeAfter > 0);
    }

    function test_execute_insufficient_confirmations_reverts() public {
        bytes memory data = abi.encodeCall(ZeroVault.unpause, ());
        vm.prank(guardian1);
        bytes32 id = timelock.propose(address(vault), 0, data);

        vm.warp(block.timestamp + DELAY);

        vm.expectRevert("insufficient confirmations");
        timelock.execute(id);
    }

    function test_execute_double_reverts() public {
        vm.prank(guardian1);
        vault.pause();

        bytes memory data = abi.encodeCall(ZeroVault.unpause, ());
        vm.prank(guardian1);
        bytes32 id = timelock.propose(address(vault), 0, data);

        vm.prank(guardian2);
        timelock.confirm(id);

        vm.warp(block.timestamp + DELAY);
        timelock.execute(id);

        vm.expectRevert("already executed");
        timelock.execute(id);
    }

    function test_execute_cancelled_reverts() public {
        bytes memory data = abi.encodeCall(ZeroVault.unpause, ());
        vm.prank(guardian1);
        bytes32 id = timelock.propose(address(vault), 0, data);

        vm.prank(guardian2);
        timelock.confirm(id);

        vm.prank(guardian1);
        timelock.cancel(id);

        vm.warp(block.timestamp + DELAY);

        vm.expectRevert("already cancelled");
        timelock.execute(id);
    }

    function test_execute_nonexistent_reverts() public {
        vm.expectRevert("proposal not found");
        timelock.execute(bytes32(uint256(999)));
    }

    function test_execute_expired_reverts() public {
        vm.prank(guardian1);
        vault.pause();

        bytes memory data = abi.encodeCall(ZeroVault.unpause, ());
        vm.prank(guardian1);
        bytes32 id = timelock.propose(address(vault), 0, data);

        vm.prank(guardian2);
        timelock.confirm(id);

        // Warp past delay + grace period
        vm.warp(block.timestamp + DELAY + 14 days + 1);

        vm.expectRevert("proposal expired");
        timelock.execute(id);
    }

    function test_execute_bubbles_revert() public {
        // Try to execute removeToken for token that's already removed — should work
        // Instead test: call a function that will fail
        // Execute queueGuardianRotation with an existing guardian — should revert
        bytes memory data = abi.encodeCall(ZeroVault.queueGuardianRotation, (0, guardian1));
        vm.prank(guardian1);
        bytes32 id = timelock.propose(address(vault), 0, data);

        vm.prank(guardian2);
        timelock.confirm(id);

        vm.warp(block.timestamp + DELAY);

        // Should bubble up "already a guardian"
        vm.expectRevert("already a guardian");
        timelock.execute(id);
    }

    function test_execute_emits_event() public {
        vm.prank(guardian1);
        vault.pause();

        bytes memory data = abi.encodeCall(ZeroVault.unpause, ());
        vm.prank(guardian1);
        bytes32 id = timelock.propose(address(vault), 0, data);

        vm.prank(guardian2);
        timelock.confirm(id);

        vm.warp(block.timestamp + DELAY);

        vm.expectEmit(true, false, false, false);
        emit ZeroTimelock.ProposalExecuted(id);
        timelock.execute(id);
    }

    // ============================================================
    //                      CANCEL TESTS
    // ============================================================

    function test_cancel() public {
        bytes memory data = abi.encodeCall(ZeroVault.unpause, ());
        vm.prank(guardian1);
        bytes32 id = timelock.propose(address(vault), 0, data);

        vm.prank(guardian1);
        timelock.cancel(id);

        (,,,,, bool executed, bool cancelled,) = timelock.getProposal(id);
        assertFalse(executed);
        assertTrue(cancelled);
    }

    function test_cancel_only_proposer() public {
        bytes memory data = abi.encodeCall(ZeroVault.unpause, ());
        vm.prank(guardian1);
        bytes32 id = timelock.propose(address(vault), 0, data);

        vm.prank(guardian2);
        vm.expectRevert("only proposer can cancel");
        timelock.cancel(id);
    }

    function test_cancel_non_guardian_reverts() public {
        bytes memory data = abi.encodeCall(ZeroVault.unpause, ());
        vm.prank(guardian1);
        bytes32 id = timelock.propose(address(vault), 0, data);

        vm.prank(alice);
        vm.expectRevert("not guardian");
        timelock.cancel(id);
    }

    function test_cancel_already_executed_reverts() public {
        vm.prank(guardian1);
        vault.pause();

        bytes memory data = abi.encodeCall(ZeroVault.unpause, ());
        vm.prank(guardian1);
        bytes32 id = timelock.propose(address(vault), 0, data);

        vm.prank(guardian2);
        timelock.confirm(id);

        vm.warp(block.timestamp + DELAY);
        timelock.execute(id);

        vm.prank(guardian1);
        vm.expectRevert("already executed");
        timelock.cancel(id);
    }

    function test_cancel_double_reverts() public {
        bytes memory data = abi.encodeCall(ZeroVault.unpause, ());
        vm.prank(guardian1);
        bytes32 id = timelock.propose(address(vault), 0, data);

        vm.prank(guardian1);
        timelock.cancel(id);

        vm.prank(guardian1);
        vm.expectRevert("already cancelled");
        timelock.cancel(id);
    }

    function test_cancel_emits_event() public {
        bytes memory data = abi.encodeCall(ZeroVault.unpause, ());
        vm.prank(guardian1);
        bytes32 id = timelock.propose(address(vault), 0, data);

        vm.expectEmit(true, false, false, false);
        emit ZeroTimelock.ProposalCancelled(id);

        vm.prank(guardian1);
        timelock.cancel(id);
    }

    // ============================================================
    //                   SELF-GOVERNANCE TESTS
    // ============================================================

    function test_set_delay_via_proposal() public {
        uint256 newDelay = 48 hours;
        bytes memory data = abi.encodeCall(ZeroTimelock.setDelay, (newDelay));

        vm.prank(guardian1);
        bytes32 id = timelock.propose(address(timelock), 0, data);

        vm.prank(guardian2);
        timelock.confirm(id);

        vm.warp(block.timestamp + DELAY);
        timelock.execute(id);

        assertEq(timelock.delay(), newDelay);
    }

    function test_set_delay_direct_reverts() public {
        vm.prank(guardian1);
        vm.expectRevert("not self");
        timelock.setDelay(48 hours);
    }

    function test_set_delay_too_long_reverts() public {
        bytes memory data = abi.encodeCall(ZeroTimelock.setDelay, (31 days));

        vm.prank(guardian1);
        bytes32 id = timelock.propose(address(timelock), 0, data);

        vm.prank(guardian2);
        timelock.confirm(id);

        vm.warp(block.timestamp + DELAY);

        vm.expectRevert("delay too long");
        timelock.execute(id);
    }

    function test_rotate_guardian_via_proposal() public {
        address newGuardian = address(0x4004);
        bytes memory data = abi.encodeCall(ZeroTimelock.rotateGuardian, (2, newGuardian));

        vm.prank(guardian1);
        bytes32 id = timelock.propose(address(timelock), 0, data);

        vm.prank(guardian2);
        timelock.confirm(id);

        vm.warp(block.timestamp + DELAY);
        timelock.execute(id);

        assertEq(timelock.guardians(2), newGuardian);
        assertTrue(timelock.isGuardian(newGuardian));
        assertFalse(timelock.isGuardian(guardian3));
    }

    function test_rotate_guardian_direct_reverts() public {
        vm.prank(guardian1);
        vm.expectRevert("not self");
        timelock.rotateGuardian(0, address(0x4004));
    }

    function test_rotate_guardian_duplicate_reverts() public {
        bytes memory data = abi.encodeCall(ZeroTimelock.rotateGuardian, (2, guardian1));

        vm.prank(guardian1);
        bytes32 id = timelock.propose(address(timelock), 0, data);

        vm.prank(guardian2);
        timelock.confirm(id);

        vm.warp(block.timestamp + DELAY);

        vm.expectRevert("already guardian");
        timelock.execute(id);
    }

    function test_rotate_guardian_invalid_index_reverts() public {
        bytes memory data = abi.encodeCall(ZeroTimelock.rotateGuardian, (3, address(0x4004)));

        vm.prank(guardian1);
        bytes32 id = timelock.propose(address(timelock), 0, data);

        vm.prank(guardian2);
        timelock.confirm(id);

        vm.warp(block.timestamp + DELAY);

        vm.expectRevert("invalid index");
        timelock.execute(id);
    }

    // ============================================================
    //                      VIEW TESTS
    // ============================================================

    function test_isReady() public {
        vm.prank(guardian1);
        vault.pause();

        bytes memory data = abi.encodeCall(ZeroVault.unpause, ());
        vm.prank(guardian1);
        bytes32 id = timelock.propose(address(vault), 0, data);

        // Not ready — only 1 confirmation
        assertFalse(timelock.isReady(id));

        vm.prank(guardian2);
        timelock.confirm(id);

        // Not ready — delay not elapsed
        assertFalse(timelock.isReady(id));

        vm.warp(block.timestamp + DELAY);

        // Ready
        assertTrue(timelock.isReady(id));

        // Execute it
        timelock.execute(id);

        // No longer ready
        assertFalse(timelock.isReady(id));
    }

    function test_isReady_expired() public {
        vm.prank(guardian1);
        vault.pause();

        bytes memory data = abi.encodeCall(ZeroVault.unpause, ());
        vm.prank(guardian1);
        bytes32 id = timelock.propose(address(vault), 0, data);

        vm.prank(guardian2);
        timelock.confirm(id);

        vm.warp(block.timestamp + DELAY + 14 days + 1);

        assertFalse(timelock.isReady(id));
    }

    function test_isReady_nonexistent() public view {
        assertFalse(timelock.isReady(bytes32(uint256(999))));
    }

    // ============================================================
    //                  ZERO DELAY (TESTNET) TESTS
    // ============================================================

    function test_zero_delay_immediate_execution() public {
        ZeroTimelock testnetTimelock = new ZeroTimelock([guardian1, guardian2, guardian3], 0);

        // Deploy vault with testnet timelock as admin
        MockERC20 token = new MockERC20("Test", "TST", 18);
        address[] memory tokens = new address[](1);
        tokens[0] = address(token);
        ZeroVault testVault = new ZeroVault([guardian1, guardian2, guardian3], tokens, address(testnetTimelock));

        // Pause it
        vm.prank(guardian1);
        testVault.pause();
        assertTrue(testVault.paused());

        // Propose + confirm + execute in same block
        bytes memory data = abi.encodeCall(ZeroVault.unpause, ());
        vm.prank(guardian1);
        bytes32 id = testnetTimelock.propose(address(testVault), 0, data);

        vm.prank(guardian2);
        testnetTimelock.confirm(id);

        // No warp needed — zero delay
        testnetTimelock.execute(id);

        assertFalse(testVault.paused());
    }

    // ============================================================
    //                  INTEGRATION: FULL FLOW
    // ============================================================

    function test_full_admin_transfer_flow() public {
        // This test simulates the full migration:
        // 1. Timelock is already admin (set in setUp)
        // 2. Propose addToken via timelock
        // 3. Confirm with 2nd guardian
        // 4. Wait for delay
        // 5. Execute

        MockERC20 dai = new MockERC20("Dai", "DAI", 18);

        // Step 1: Guardian proposes adding DAI
        bytes memory data = abi.encodeCall(ZeroVault.addToken, (address(dai)));
        vm.prank(guardian1);
        bytes32 id = timelock.propose(address(vault), 0, data);

        // Step 2: Another guardian confirms
        vm.prank(guardian3);
        timelock.confirm(id);

        // Step 3: Delay hasn't passed yet — cannot execute
        vm.expectRevert("delay not elapsed");
        timelock.execute(id);

        // Step 4: Wait for delay
        vm.warp(block.timestamp + DELAY);

        // Step 5: Anyone can execute
        vm.prank(address(0xCAFE));
        timelock.execute(id);

        // Verify
        assertTrue(vault.supportedTokens(address(dai)));
    }

    function test_multiple_proposals_independent() public {
        MockERC20 dai = new MockERC20("Dai", "DAI", 18);
        MockERC20 frax = new MockERC20("Frax", "FRAX", 18);

        // Propose adding DAI
        bytes memory data1 = abi.encodeCall(ZeroVault.addToken, (address(dai)));
        vm.prank(guardian1);
        bytes32 id1 = timelock.propose(address(vault), 0, data1);

        // Propose adding FRAX
        bytes memory data2 = abi.encodeCall(ZeroVault.addToken, (address(frax)));
        vm.prank(guardian2);
        bytes32 id2 = timelock.propose(address(vault), 0, data2);

        // Confirm both
        vm.prank(guardian2);
        timelock.confirm(id1);
        vm.prank(guardian3);
        timelock.confirm(id2);

        // Cancel id1 (DAI)
        vm.prank(guardian1);
        timelock.cancel(id1);

        // Warp and execute id2 (FRAX) — should work independently
        vm.warp(block.timestamp + DELAY);
        timelock.execute(id2);

        assertFalse(vault.supportedTokens(address(dai))); // was cancelled
        assertTrue(vault.supportedTokens(address(frax)));  // was executed
    }

    function test_nonce_increments() public {
        assertEq(timelock.nonce(), 0);

        bytes memory data = abi.encodeCall(ZeroVault.unpause, ());

        vm.prank(guardian1);
        timelock.propose(address(vault), 0, data);
        assertEq(timelock.nonce(), 1);

        vm.prank(guardian2);
        timelock.propose(address(vault), 0, data);
        assertEq(timelock.nonce(), 2);
    }

    // ============================================================
    //                    RECEIVE ETH TEST
    // ============================================================

    function test_receive_eth() public {
        vm.deal(address(this), 1 ether);
        (bool ok,) = address(timelock).call{value: 1 ether}("");
        assertTrue(ok);
        assertEq(address(timelock).balance, 1 ether);
    }
}
