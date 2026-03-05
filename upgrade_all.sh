#!/bin/bash

# ═══════════════════════════════════════════════════════════════════════════
# Phoenix Protocol - Batch Upgrade Script for yPUSD and Farm
# ═══════════════════════════════════════════════════════════════════════════

source .env

# Contract proxy addresses (same across all chains via CREATE2)
# These are the PROXY addresses, not implementation addresses!
export YPUSD=0x5E16e1F5BABE0b86094fbfC11EC0849F6B07f487
export FARM=0x0020cA402e8b928FcCE234C00cab0De1c74Ca72d

# Chain configurations: chainId|rpcVar|name|verifierUrl|verifierType
CHAINS=(
    "56|RPC_BSC|BSC|https://api.bscscan.com/api|etherscan"
    "42161|RPC_ARB|Arbitrum|https://api.arbiscan.io/api|etherscan"
    "137|RPC_POLYGON|Polygon|https://api.polygonscan.com/api|etherscan"
    "43114|RPC_AVAX|Avalanche|https://api.snowtrace.io/api|etherscan"
    "1|RPC_ETH|Ethereum|https://api.etherscan.io/api|etherscan"
    "8453|RPC_BASE|Base|https://api.basescan.org/api|etherscan"
    "10|RPC_OP|Optimism|https://api-optimistic.etherscan.io/api|etherscan"
    "143|RPC_MONAD|Monad|https://sourcify-api-monad.blockvision.org|sourcify"
)

echo "═══════════════════════════════════════════════════════════════════"
echo "Starting batch upgrade for yPUSD and Farm contracts"
echo "═══════════════════════════════════════════════════════════════════"

for chain_config in "${CHAINS[@]}"; do
    IFS='|' read -r CHAIN_ID RPC_VAR CHAIN_NAME VERIFIER_URL VERIFIER_TYPE <<< "$chain_config"
    
    # Get RPC URL from env var
    RPC_URL="${!RPC_VAR}"
    
    if [ -z "$RPC_URL" ]; then
        echo "⚠️  Skipping $CHAIN_NAME (Chain $CHAIN_ID) - RPC not configured"
        continue
    fi
    
    echo ""
    echo "═══════════════════════════════════════════════════════════════════"
    echo "📍 Upgrading on $CHAIN_NAME (Chain ID: $CHAIN_ID)"
    echo "═══════════════════════════════════════════════════════════════════"
    
    # Upgrade yPUSD
    echo ""
    echo "🔄 Upgrading yPUSD..."
    forge script script/token/yPUSD_Deployer.s.sol:yPUSD_Deployer \
        --sig "upgrade()" \
        --rpc-url "$RPC_URL" \
        --private-key "$PRIVATE_KEY" \
        --broadcast \
        -vvv
    
    if [ $? -eq 0 ]; then
        echo "✅ yPUSD upgraded on $CHAIN_NAME"
    else
        echo "❌ yPUSD upgrade FAILED on $CHAIN_NAME"
    fi
    
    # Upgrade Farm
    echo ""
    echo "🔄 Upgrading Farm..."
    forge script script/Farm/Farm_Deployer.s.sol:Farm_Deployer \
        --sig "upgrade()" \
        --rpc-url "$RPC_URL" \
        --private-key "$PRIVATE_KEY" \
        --broadcast \
        -vvv
    
    if [ $? -eq 0 ]; then
        echo "✅ Farm upgraded on $CHAIN_NAME"
    else
        echo "❌ Farm upgrade FAILED on $CHAIN_NAME"
    fi
    
    echo ""
    echo "───────────────────────────────────────────────────────────────────"
done

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "🎉 Batch upgrade complete!"
echo "═══════════════════════════════════════════════════════════════════"
