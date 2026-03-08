#!/usr/bin/env bash
# Deploy ZeroVault to testnets.
#
# Usage:
#   ./script/deploy-testnet.sh base-sepolia    # Deploy with USDC on Base Sepolia
#   ./script/deploy-testnet.sh arbitrum-sepolia # Deploy with USDT on Arbitrum Sepolia
#   ./script/deploy-testnet.sh both            # Deploy to both
#
# Prerequisites:
#   1. Copy .env.example to .env and fill in all values
#   2. Fund deployer address with testnet ETH on target chain(s)
#   3. Ensure forge is installed (foundryup)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONTRACT_DIR="$(dirname "$SCRIPT_DIR")"
cd "$CONTRACT_DIR"

# Load .env
if [ ! -f .env ]; then
    echo "Error: .env not found. Copy .env.example to .env and fill in values."
    exit 1
fi
source .env

deploy_base_sepolia() {
    echo "=== Deploying ZeroVault to Base Sepolia ==="
    echo "  RPC: $BASE_SEPOLIA_RPC"
    echo "  Token (USDC): $BASE_SEPOLIA_USDC"
    echo "  Admin: $ADMIN_ADDRESS"
    echo ""

    TOKEN_ADDRESS="$BASE_SEPOLIA_USDC" \
    forge script script/Deploy.s.sol \
        --rpc-url "$BASE_SEPOLIA_RPC" \
        --broadcast \
        --slow \
        -vvv

    echo ""
    echo "=== Base Sepolia deployment complete ==="
    echo "Check the broadcast/ directory for deployment artifacts."
}

deploy_arbitrum_sepolia() {
    echo "=== Deploying ZeroVault to Arbitrum Sepolia ==="
    echo "  RPC: $ARBITRUM_SEPOLIA_RPC"
    echo "  Token (USDT): $ARBITRUM_SEPOLIA_USDT"
    echo "  Admin: $ADMIN_ADDRESS"
    echo ""

    TOKEN_ADDRESS="$ARBITRUM_SEPOLIA_USDT" \
    forge script script/Deploy.s.sol \
        --rpc-url "$ARBITRUM_SEPOLIA_RPC" \
        --broadcast \
        --slow \
        -vvv

    echo ""
    echo "=== Arbitrum Sepolia deployment complete ==="
    echo "Check the broadcast/ directory for deployment artifacts."
}

case "${1:-}" in
    base-sepolia)
        deploy_base_sepolia
        ;;
    arbitrum-sepolia)
        deploy_arbitrum_sepolia
        ;;
    both)
        deploy_base_sepolia
        echo ""
        deploy_arbitrum_sepolia
        ;;
    *)
        echo "Usage: $0 {base-sepolia|arbitrum-sepolia|both}"
        exit 1
        ;;
esac
