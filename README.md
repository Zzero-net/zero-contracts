# Zero Contracts

Solidity bridge contracts for the **Zero Network** — a permissionless stablecoin microtransaction network.

Built with [Foundry](https://getfoundry.sh). 98 tests. Apache-2.0.

## Overview

Zero uses vault contracts on L2 chains to lock stablecoins and mint Z tokens on the Zero network. The bridge is secured by **Trinity Validators** — three independent parties that collectively sign all minting and release operations via 2-of-3 multisig with EIP-712 typed signatures.

```
User deposits USDC/USDT → ZeroVault locks tokens → Trinity Validators observe → Z minted on Zero
User burns Z on Zero → Trinity Validators sign release → ZeroVault releases USDC/USDT to user
```

## Contracts

### ZeroVault

The core bridge contract. Deployed on each supported L2 chain.

| Chain | Asset | Address |
|-------|-------|---------|
| Base | USDC | [`0x2F0D...b298`](https://basescan.org/address/0x2F0D9aCa8727ae54a750aEe418237e0e26C5b298) |
| Arbitrum | USDC | [`0x604D...2b24`](https://arbiscan.io/address/0x604D159322C948Cb0a0E07cD5B76EbD52e082b24) |

**Key functions:**

- `deposit(token, amount, zeroRecipient)` — Lock stablecoins, emits `Deposited` event observed by bridge watchers
- `release(token, amount, recipient, bridgeId, signatures)` — Release stablecoins with 2-of-3 guardian signatures
- `pause()` / `unpause()` — Asymmetric: any single guardian can pause, only admin (timelock) can unpause

**Security features:**

- **Tiered circuit breaker**: 2-of-3 sigs for <=20% of reserves per 24h, 3-of-3 for 20-50%, auto-revert above 50%
- **EIP-712 typed signatures**: Human-readable signing, prevents cross-chain replay
- **Replay protection**: Each `bridgeId` can only be processed once
- **ReentrancyGuard**: On all fund-moving functions
- **48h guardian rotation delay**: Queued, then executed after delay
- **Role-based access**: OpenZeppelin AccessControl (not Ownable)

**Roles:**

| Role | Holder | Powers |
|------|--------|--------|
| `PAUSER_ROLE` | Each guardian (3) | Emergency pause |
| `DEFAULT_ADMIN_ROLE` | ZeroTimelock | Unpause, guardian rotation, token management |

### ZeroTimelock

Minimal 2-of-3 timelock controller. Holds admin rights over ZeroVault, so all admin operations go through a timelocked multisig proposal process.

| Chain | Address |
|-------|---------|
| Base | [`0xa63a...098c`](https://basescan.org/address/0xa63aA579e69947e8784b903F435ECF47328C098c) |
| Arbitrum | [`0x077d...1a7a`](https://arbiscan.io/address/0x077dB504F46E3fd6059012409D1F4ab680d81a7a) |

**Proposal flow:**

1. Guardian calls `propose(target, value, data)` — creates proposal, auto-confirms
2. Second guardian calls `confirm(proposalId)` — reaches 2-of-3 threshold
3. After timelock delay (24h mainnet), anyone calls `execute(proposalId)` — executes the action
4. Proposals expire after `delay + 14 day grace period`

**Parameters:**

| Parameter | Value |
|-----------|-------|
| Guardian count | 3 |
| Threshold | 2-of-3 |
| Timelock delay | 24 hours (mainnet) |
| Grace period | 14 days |
| Max delay | 30 days |

**Self-governance:** The timelock can modify its own parameters (delay, guardian rotation) via proposals targeting itself.

## Development

### Build

```bash
forge build
```

### Test

```bash
forge test -vvv
```

98 tests across 3 test files:

- `ZeroVault.t.sol` — Deposits, releases, EIP-712 signatures, circuit breaker tiers, asymmetric pause, guardian rotation, token management, access control
- `ZeroTimelock.t.sol` — Proposal lifecycle, confirmations, execution, cancellation, self-governance, zero-delay testnet mode
- `CrossBridge.t.sol` — EIP-712 digest compatibility with Rust bridge signer, 2-of-3 and 3-of-3 signing flows

### Deploy

```bash
# Deploy timelock
forge script script/DeployTimelock.s.sol --rpc-url $RPC_URL --broadcast

# Deploy vault with timelock as admin
forge script script/Deploy.s.sol --rpc-url $RPC_URL --broadcast
```

### CI

GitHub Actions runs `forge build` and `forge test -vvv` on every push and PR to `main`.

## Dependencies

- [OpenZeppelin Contracts v5](https://github.com/OpenZeppelin/openzeppelin-contracts) — AccessControl, SafeERC20, ECDSA, EIP712, ReentrancyGuard
- [Foundry](https://getfoundry.sh) — Build, test, deploy toolchain

## Related

| Resource | Link |
|----------|------|
| Zero Chain (Rust node) | [zero-chain](https://github.com/Zzero-net/zero-chain) |
| Python SDK | [zero-sdk-python](https://github.com/Zzero-net/zero-sdk-python) |
| JavaScript SDK | [zero-sdk-js](https://github.com/Zzero-net/zero-sdk-js) |
| Documentation | [docs.zzero.net](https://docs.zzero.net) |
| Explorer | [explorer.zzero.net](https://explorer.zzero.net) |

## License

Apache-2.0
