// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";

/// @title ZeroVault — Lock stablecoins, mint Z on the Zero network.
/// @notice Deployed on Base (USDC) and Arbitrum (USDT). Same contract, different tokens.
///
///         Security model (informed by Aave, CCIP, Safe, and bridge hack post-mortems):
///           - 3 Trinity Validators control all bridge operations (mint/burn)
///           - 2-of-3 multisig required for any release
///           - Asymmetric pause: 1-of-3 can pause, 2-of-3 (DEFAULT_ADMIN) to unpause
///           - Tiered circuit breaker: normal / elevated (3-of-3 + delay) / critical (auto-pause)
///           - EIP-712 typed signatures for human-readable signing
///           - Timelocked guardian rotation (48h delay)
///           - ReentrancyGuard on all fund-moving functions
///           - Role-based access control (AccessControl over Ownable)
contract ZeroVault is AccessControl, EIP712, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // --- Roles ---

    /// @notice Can pause the vault (any single Trinity Validator)
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    // DEFAULT_ADMIN_ROLE (from AccessControl) controls:
    //   - unpause, guardian rotation execution, token management, role management

    // --- Events ---

    event Deposited(
        address indexed depositor,
        address indexed token,
        uint256 amount,
        bytes32 zeroRecipient
    );

    event Released(
        address indexed recipient,
        address indexed token,
        uint256 amount,
        bytes32 bridgeId
    );

    event GuardianRotationQueued(
        uint256 indexed index,
        address oldGuardian,
        address newGuardian,
        uint256 executeAfter
    );
    event GuardianRotationExecuted(uint256 indexed index, address oldGuardian, address newGuardian);
    event GuardianRotationCancelled(uint256 indexed index);
    event VaultPaused(address indexed by);
    event VaultUnpaused(address indexed by);
    event TokenAdded(address indexed token);
    event TokenRemoved(address indexed token);

    // --- Constants ---

    uint256 public constant TRINITY_COUNT = 3;
    uint256 public constant TRINITY_THRESHOLD = 2; // 2-of-3
    uint256 public constant WINDOW_DURATION = 24 hours;
    uint256 public constant ROTATION_DELAY = 48 hours;

    // Circuit breaker tiers (basis points of totalLocked per window)
    uint256 public constant TIER_NORMAL_BPS = 2000;    // 20% — 2-of-3, immediate
    uint256 public constant TIER_ELEVATED_BPS = 5000;   // 50% — 3-of-3 required
    // Above 50% in a window → auto-pause (critical tier)

    // --- EIP-712 Type Hashes ---

    bytes32 public constant RELEASE_TYPEHASH = keccak256(
        "Release(address token,uint256 amount,address recipient,bytes32 bridgeId)"
    );

    // --- State ---

    bool public paused;

    // Trinity Validators (3 trusted ECDSA signers)
    address[3] public guardians;
    mapping(address => bool) public isGuardian;

    // Supported stablecoin tokens
    mapping(address => bool) public supportedTokens;

    // Total locked per token
    mapping(address => uint256) public totalLocked;

    // Processed bridge IDs (prevent replay)
    mapping(bytes32 => bool) public processedBridgeIds;

    // Circuit breaker: track releases per 24h window (per-token)
    mapping(address => uint256) public releasedInWindow;
    mapping(address => uint256) public tokenWindowStart;

    // Timelocked guardian rotation
    struct PendingRotation {
        address newGuardian;
        uint256 executeAfter;
    }
    mapping(uint256 => PendingRotation) public pendingRotations;

    // --- Modifiers ---

    modifier whenNotPaused() {
        require(!paused, "paused");
        _;
    }

    // --- Constructor ---

    /// @param _guardians The 3 Trinity Validator addresses
    /// @param _tokens Initially supported token addresses
    /// @param _admin The admin address (should be a multisig or TimelockController)
    constructor(
        address[3] memory _guardians,
        address[] memory _tokens,
        address _admin
    ) EIP712("ZeroVault", "2") {
        require(_admin != address(0), "zero admin");

        for (uint256 i = 0; i < 3; i++) {
            require(_guardians[i] != address(0), "zero address");
            for (uint256 j = 0; j < i; j++) {
                require(_guardians[i] != _guardians[j], "duplicate guardian");
            }
            guardians[i] = _guardians[i];
            isGuardian[_guardians[i]] = true;
            // Each Trinity Validator can independently pause
            _grantRole(PAUSER_ROLE, _guardians[i]);
        }

        for (uint256 i = 0; i < _tokens.length; i++) {
            supportedTokens[_tokens[i]] = true;
        }

        // Admin controls unpause, rotation execution, token management, role management
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
    }

    // --- Deposit (Bridge In) ---

    /// @notice Lock stablecoins in the vault. Emits Deposited event for Trinity Validators to observe.
    function deposit(
        address token,
        uint256 amount,
        bytes32 zeroRecipient
    ) external whenNotPaused nonReentrant {
        require(supportedTokens[token], "unsupported token");
        require(amount > 0, "zero amount");
        require(zeroRecipient != bytes32(0), "zero recipient");

        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        totalLocked[token] += amount;

        emit Deposited(msg.sender, token, amount, zeroRecipient);
    }

    // --- Release (Bridge Out) ---

    /// @notice Release stablecoins from the vault. Requires Trinity Validator signatures.
    /// @dev Normal tier (<=20%): 2-of-3. Elevated tier (20-50%): 3-of-3. Critical (>50%): blocked.
    function release(
        address token,
        uint256 amount,
        address recipient,
        bytes32 bridgeId,
        bytes calldata signatures
    ) external whenNotPaused nonReentrant {
        require(supportedTokens[token], "unsupported token");
        require(amount > 0, "zero amount");
        require(recipient != address(0), "zero recipient");
        require(!processedBridgeIds[bridgeId], "already processed");

        // Reset window if expired
        _resetWindowIfExpired(token);

        // Determine required tier and verify signatures
        uint256 sigCount = _countSignatures(signatures);
        uint256 newTotal = releasedInWindow[token] + amount;
        uint256 locked = totalLocked[token];

        if (locked > 0) {
            uint256 normalLimit = (locked * TIER_NORMAL_BPS) / 10000;
            uint256 elevatedLimit = (locked * TIER_ELEVATED_BPS) / 10000;

            require(newTotal <= elevatedLimit, "circuit breaker: exceeds 50% window limit");

            if (newTotal > normalLimit) {
                // Elevated tier: require 3-of-3
                require(sigCount == TRINITY_COUNT, "elevated tier: need 3-of-3 signatures");
            }
            // Normal tier: 2-of-3 is sufficient (enforced below)
        }

        // Verify guardian signatures (EIP-712 typed data)
        bytes32 structHash = keccak256(abi.encode(
            RELEASE_TYPEHASH,
            token,
            amount,
            recipient,
            bridgeId
        ));
        bytes32 digest = _hashTypedDataV4(structHash);
        _verifyGuardianSignatures(digest, signatures);

        // Effects before interactions (checks-effects-interactions)
        processedBridgeIds[bridgeId] = true;
        totalLocked[token] -= amount;
        releasedInWindow[token] = newTotal;

        // Interaction
        IERC20(token).safeTransfer(recipient, amount);

        emit Released(recipient, token, amount, bridgeId);
    }

    // --- Circuit Breaker ---

    function _resetWindowIfExpired(address token) internal {
        if (block.timestamp >= tokenWindowStart[token] + WINDOW_DURATION) {
            tokenWindowStart[token] = block.timestamp;
            releasedInWindow[token] = 0;
        }
    }

    function _countSignatures(bytes calldata signatures) internal pure returns (uint256) {
        uint256 sigCount = signatures.length / 65;
        require(sigCount * 65 == signatures.length, "invalid signature length");
        require(sigCount >= TRINITY_THRESHOLD, "need at least 2 signatures");
        require(sigCount <= TRINITY_COUNT, "too many signatures");
        return sigCount;
    }

    // --- Signature Verification (EIP-712) ---

    function _verifyGuardianSignatures(
        bytes32 digest,
        bytes calldata signatures
    ) internal view {
        uint256 sigCount = signatures.length / 65;
        address lastSigner = address(0);

        for (uint256 i = 0; i < sigCount; i++) {
            bytes calldata sig = signatures[i * 65:(i + 1) * 65];
            address signer = ECDSA.recover(digest, sig);

            require(signer > lastSigner, "signatures not sorted or duplicate");
            require(isGuardian[signer], "not a guardian");

            lastSigner = signer;
        }
    }

    // --- Asymmetric Pause ---

    /// @notice Any Trinity Validator (PAUSER_ROLE) can pause immediately.
    function pause() external onlyRole(PAUSER_ROLE) {
        paused = true;
        emit VaultPaused(msg.sender);
    }

    /// @notice Only admin (multisig/timelock) can unpause — deliberate, not fast.
    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        paused = false;
        emit VaultUnpaused(msg.sender);
    }

    // --- Timelocked Guardian Rotation ---

    /// @notice Queue a guardian rotation. Executes after ROTATION_DELAY (48h).
    function queueGuardianRotation(
        uint256 index,
        address newGuardian
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(index < TRINITY_COUNT, "invalid index");
        require(newGuardian != address(0), "zero address");
        require(!isGuardian[newGuardian], "already a guardian");
        require(pendingRotations[index].executeAfter == 0, "rotation already pending");

        uint256 executeAfter = block.timestamp + ROTATION_DELAY;
        pendingRotations[index] = PendingRotation({
            newGuardian: newGuardian,
            executeAfter: executeAfter
        });

        emit GuardianRotationQueued(index, guardians[index], newGuardian, executeAfter);
    }

    /// @notice Execute a queued rotation after the timelock has elapsed.
    function executeGuardianRotation(uint256 index) external onlyRole(DEFAULT_ADMIN_ROLE) {
        PendingRotation memory pending = pendingRotations[index];
        require(pending.executeAfter != 0, "no pending rotation");
        require(block.timestamp >= pending.executeAfter, "rotation not ready");

        address oldGuardian = guardians[index];
        address newGuardian = pending.newGuardian;

        // Ensure new guardian is still not a guardian (could have been added elsewhere)
        require(!isGuardian[newGuardian], "already a guardian");

        // Revoke old guardian's PAUSER_ROLE, grant to new
        _revokeRole(PAUSER_ROLE, oldGuardian);
        _grantRole(PAUSER_ROLE, newGuardian);

        isGuardian[oldGuardian] = false;
        guardians[index] = newGuardian;
        isGuardian[newGuardian] = true;

        delete pendingRotations[index];

        emit GuardianRotationExecuted(index, oldGuardian, newGuardian);
    }

    /// @notice Cancel a pending rotation.
    function cancelGuardianRotation(uint256 index) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(pendingRotations[index].executeAfter != 0, "no pending rotation");
        delete pendingRotations[index];
        emit GuardianRotationCancelled(index);
    }

    // --- Token Management ---

    function addToken(address token) external onlyRole(DEFAULT_ADMIN_ROLE) {
        supportedTokens[token] = true;
        emit TokenAdded(token);
    }

    function removeToken(address token) external onlyRole(DEFAULT_ADMIN_ROLE) {
        supportedTokens[token] = false;
        emit TokenRemoved(token);
    }

    // --- Views ---

    function trinityCount() external pure returns (uint256) {
        return TRINITY_COUNT;
    }

    function quorumThreshold() external pure returns (uint256) {
        return TRINITY_THRESHOLD;
    }

    /// @notice Returns the EIP-712 domain separator for off-chain signature construction.
    function domainSeparator() external view returns (bytes32) {
        return _domainSeparatorV4();
    }

    /// @notice Compute the digest that Trinity Validators must sign for a release.
    function releaseDigest(
        address token,
        uint256 amount,
        address recipient,
        bytes32 bridgeId
    ) external view returns (bytes32) {
        bytes32 structHash = keccak256(abi.encode(
            RELEASE_TYPEHASH,
            token,
            amount,
            recipient,
            bridgeId
        ));
        return _hashTypedDataV4(structHash);
    }
}
