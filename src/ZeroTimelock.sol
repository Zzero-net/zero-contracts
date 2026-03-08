// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

/// @title ZeroTimelock — Minimal 2-of-3 timelock controller for ZeroVault admin.
/// @notice Replaces the single-EOA admin with a timelocked multisig.
///
///         Design:
///           - 3 guardians (the Trinity Validators), 2-of-3 threshold
///           - Any guardian can propose a transaction
///           - 2 guardians must confirm before execution
///           - Configurable delay enforced between proposal and execution
///           - Proposer can cancel before execution
///           - No external dependencies — fully self-contained
///
///         This contract should be granted DEFAULT_ADMIN_ROLE on ZeroVault,
///         making all admin operations (unpause, guardian rotation, token mgmt)
///         go through the timelock.
contract ZeroTimelock {
    // --- Events ---

    event ProposalCreated(
        bytes32 indexed proposalId,
        address indexed proposer,
        address target,
        uint256 value,
        bytes data,
        uint256 executeAfter
    );
    event ProposalConfirmed(bytes32 indexed proposalId, address indexed guardian);
    event ProposalExecuted(bytes32 indexed proposalId);
    event ProposalCancelled(bytes32 indexed proposalId);
    event DelayUpdated(uint256 oldDelay, uint256 newDelay);
    event GuardianRotated(uint256 indexed index, address oldGuardian, address newGuardian);

    // --- Constants ---

    uint256 public constant GUARDIAN_COUNT = 3;
    uint256 public constant THRESHOLD = 2;

    /// @notice Maximum delay that can be set (30 days). Prevents permanent lockout.
    uint256 public constant MAX_DELAY = 30 days;

    /// @notice Grace period after delay expires — proposals expire if not executed within this window.
    uint256 public constant GRACE_PERIOD = 14 days;

    // --- State ---

    uint256 public delay;
    address[3] public guardians;
    mapping(address => bool) public isGuardian;

    struct Proposal {
        address proposer;
        address target;
        uint256 value;
        bytes data;
        uint256 executeAfter;
        bool executed;
        bool cancelled;
        uint256 confirmCount;
    }

    /// @notice All proposals by ID.
    mapping(bytes32 => Proposal) public proposals;

    /// @notice Track which guardians have confirmed each proposal.
    mapping(bytes32 => mapping(address => bool)) public confirmations;

    /// @notice Incrementing nonce for unique proposal IDs.
    uint256 public nonce;

    // --- Modifiers ---

    modifier onlyGuardian() {
        require(isGuardian[msg.sender], "not guardian");
        _;
    }

    modifier onlySelf() {
        require(msg.sender == address(this), "not self");
        _;
    }

    // --- Constructor ---

    /// @param _guardians The 3 Trinity Validator addresses
    /// @param _delay Timelock delay in seconds (e.g., 86400 for 24h, 0 for testnet)
    constructor(address[3] memory _guardians, uint256 _delay) {
        require(_delay <= MAX_DELAY, "delay too long");

        for (uint256 i = 0; i < 3; i++) {
            require(_guardians[i] != address(0), "zero address");
            for (uint256 j = 0; j < i; j++) {
                require(_guardians[i] != _guardians[j], "duplicate guardian");
            }
            guardians[i] = _guardians[i];
            isGuardian[_guardians[i]] = true;
        }

        delay = _delay;
    }

    // --- Propose ---

    /// @notice Propose a timelocked transaction. Proposer's confirmation is counted automatically.
    /// @param target The contract to call (e.g., ZeroVault address)
    /// @param value ETH value to send (usually 0)
    /// @param data The calldata (e.g., abi.encodeCall(ZeroVault.unpause, ()))
    /// @return proposalId The unique proposal identifier
    function propose(
        address target,
        uint256 value,
        bytes calldata data
    ) external onlyGuardian returns (bytes32 proposalId) {
        proposalId = keccak256(abi.encode(nonce, target, value, data));
        nonce++;

        require(proposals[proposalId].executeAfter == 0, "proposal exists");

        uint256 executeAfter = block.timestamp + delay;

        proposals[proposalId] = Proposal({
            proposer: msg.sender,
            target: target,
            value: value,
            data: data,
            executeAfter: executeAfter,
            executed: false,
            cancelled: false,
            confirmCount: 1
        });

        confirmations[proposalId][msg.sender] = true;

        emit ProposalCreated(proposalId, msg.sender, target, value, data, executeAfter);
        emit ProposalConfirmed(proposalId, msg.sender);

        return proposalId;
    }

    // --- Confirm ---

    /// @notice Confirm a pending proposal. Each guardian can confirm once.
    function confirm(bytes32 proposalId) external onlyGuardian {
        Proposal storage p = proposals[proposalId];
        require(p.executeAfter != 0, "proposal not found");
        require(!p.executed, "already executed");
        require(!p.cancelled, "already cancelled");
        require(!confirmations[proposalId][msg.sender], "already confirmed");

        confirmations[proposalId][msg.sender] = true;
        p.confirmCount++;

        emit ProposalConfirmed(proposalId, msg.sender);
    }

    // --- Execute ---

    /// @notice Execute a proposal after the delay has elapsed and threshold confirmations are met.
    /// @dev Anyone can call execute — the security is in the confirmations and delay.
    function execute(bytes32 proposalId) external {
        Proposal storage p = proposals[proposalId];
        require(p.executeAfter != 0, "proposal not found");
        require(!p.executed, "already executed");
        require(!p.cancelled, "already cancelled");
        require(p.confirmCount >= THRESHOLD, "insufficient confirmations");
        require(block.timestamp >= p.executeAfter, "delay not elapsed");
        require(block.timestamp <= p.executeAfter + GRACE_PERIOD, "proposal expired");

        p.executed = true;

        (bool success, bytes memory returnData) = p.target.call{value: p.value}(p.data);
        if (!success) {
            // Bubble up the revert reason
            if (returnData.length > 0) {
                assembly {
                    revert(add(returnData, 32), mload(returnData))
                }
            }
            revert("execution failed");
        }

        emit ProposalExecuted(proposalId);
    }

    // --- Cancel ---

    /// @notice Cancel a pending proposal. Only the original proposer can cancel.
    function cancel(bytes32 proposalId) external onlyGuardian {
        Proposal storage p = proposals[proposalId];
        require(p.executeAfter != 0, "proposal not found");
        require(!p.executed, "already executed");
        require(!p.cancelled, "already cancelled");
        require(p.proposer == msg.sender, "only proposer can cancel");

        p.cancelled = true;

        emit ProposalCancelled(proposalId);
    }

    // --- Self-Governance (called via timelock itself) ---

    /// @notice Update the timelock delay. Must be called via a timelocked proposal.
    function setDelay(uint256 newDelay) external onlySelf {
        require(newDelay <= MAX_DELAY, "delay too long");
        uint256 oldDelay = delay;
        delay = newDelay;
        emit DelayUpdated(oldDelay, newDelay);
    }

    /// @notice Rotate a guardian. Must be called via a timelocked proposal.
    /// @param index Guardian index (0, 1, or 2)
    /// @param newGuardian New guardian address
    function rotateGuardian(uint256 index, address newGuardian) external onlySelf {
        require(index < GUARDIAN_COUNT, "invalid index");
        require(newGuardian != address(0), "zero address");
        require(!isGuardian[newGuardian], "already guardian");

        address old = guardians[index];
        isGuardian[old] = false;
        guardians[index] = newGuardian;
        isGuardian[newGuardian] = true;

        emit GuardianRotated(index, old, newGuardian);
    }

    // --- Views ---

    /// @notice Check if a proposal has enough confirmations and the delay has elapsed.
    function isReady(bytes32 proposalId) external view returns (bool) {
        Proposal storage p = proposals[proposalId];
        return (
            p.executeAfter != 0 &&
            !p.executed &&
            !p.cancelled &&
            p.confirmCount >= THRESHOLD &&
            block.timestamp >= p.executeAfter &&
            block.timestamp <= p.executeAfter + GRACE_PERIOD
        );
    }

    /// @notice Get full proposal details.
    function getProposal(bytes32 proposalId)
        external
        view
        returns (
            address proposer,
            address target,
            uint256 value,
            bytes memory data,
            uint256 executeAfter,
            bool executed,
            bool cancelled,
            uint256 confirmCount
        )
    {
        Proposal storage p = proposals[proposalId];
        return (p.proposer, p.target, p.value, p.data, p.executeAfter, p.executed, p.cancelled, p.confirmCount);
    }

    /// @notice Check if a specific guardian has confirmed a proposal.
    function hasConfirmed(bytes32 proposalId, address guardian) external view returns (bool) {
        return confirmations[proposalId][guardian];
    }

    /// @notice Allow the contract to receive ETH (for proposals that forward value).
    receive() external payable {}
}
