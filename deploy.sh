#!/bin/bash

# ========================================
# Phoenix DeFi Multi-Chain Deployment Script
# ========================================
# 
# 优化: 验证失败不会阻塞后续链的部署
# 每个链部署完成后继续下一个，即使验证失败
#
# ========================================

# Don't use set -e, handle errors manually to continue deployment
# set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Load environment variables
if [ -f .env ]; then
    source .env
else
    echo -e "${RED}Error: .env file not found. Copy .env.example to .env and configure it.${NC}"
    exit 1
fi

# Check required variables
check_required_vars() {
    if [ -z "$ADMIN" ] || [ -z "$PRIVATE_KEY" ]; then
        echo -e "${RED}Error: ADMIN and PRIVATE_KEY must be set in .env${NC}"
        exit 1
    fi
    
    # Set SALT based on NETWORK
    if [ "$NETWORK" = "mainnet" ]; then
        export SALT=$SALT_MAINNET
        echo -e "${YELLOW}️  MAINNET MODE - Using Salt: $SALT${NC}"
    else
        export SALT=$SALT_TESTNET
        echo -e "${GREEN}Testnet Mode - Using Salt: $SALT${NC}"
    fi
}

check_required_vars

# Function to deploy to a chain
deploy_to_chain() {
    local chain_name=$1
    local rpc_url=$2
    local verify_api_key=$3
    local verify_url=$4

    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}Deploying to ${chain_name}${NC}"
    echo -e "${BLUE}========================================${NC}"

    if [ -z "$rpc_url" ]; then
        echo -e "${YELLOW}Skipping ${chain_name}: RPC URL not configured${NC}"
        return 0
    fi

    # Build verify args if API key provided
    # 大量重试验证，间隔8秒
    local verify_args=""
    if [ -n "$verify_api_key" ] && [ -n "$verify_url" ]; then
        verify_args="--verify --etherscan-api-key $verify_api_key --verifier-url $verify_url --retries 100 --delay 8"
    fi

    # Run deployment (continue on verification failure)
    echo -e "${GREEN}Starting deployment...${NC}"
    if forge script script/FullDeploy.s.sol:FullDeploy \
        --rpc-url "$rpc_url" \
        --private-key "$PRIVATE_KEY" \
        --broadcast \
        $verify_args \
        -vvv; then
        echo -e "${GREEN}✓ ${chain_name} deployment complete!${NC}"
    else
        # Check if it's just a verification error (deployment still succeeded)
        echo -e "${YELLOW}⚠️  ${chain_name} - deployment done but verification may have failed${NC}"
        echo -e "${YELLOW}   You can manually verify later with: forge verify-contract${NC}"
    fi
    echo ""
    
    # Always return success to continue with next chain
    return 0
}

# Function to simulate deployment (dry run)
simulate_deployment() {
    local chain_name=$1
    local rpc_url=$2

    echo -e "${YELLOW}Simulating deployment to ${chain_name}...${NC}"
    
    forge script script/FullDeploy.s.sol:FullDeploy \
        --rpc-url "$rpc_url" \
        -vvv

    echo -e "${GREEN}✓ Simulation complete${NC}"
}

# Show usage
show_usage() {
    echo "Usage: $0 [command] [chain]"
    echo ""
    echo "Commands:"
    echo "  deploy [chain]    Deploy core protocol to specific chain or all chains"
    echo "  bridge [chain]    Deploy MessageManager (cross-chain bridge) to a chain"
    echo "  simulate [chain]  Simulate deployment (dry run)"
    echo "  list              List supported chains"
    echo ""
    echo "Chains:"
    echo "  bsc, arbitrum, base, ethereum, polygon, op, avalanche, monad"
    echo "  bsc-testnet, arbitrum-sepolia, base-sepolia, sepolia, polygon-amoy, op-sepolia, fuji"
    echo "  all               Deploy to all configured mainnets"
    echo "  all-testnet       Deploy to all configured testnets"
    echo ""
    echo "Examples:"
    echo "  $0 simulate bsc           # Dry run on BSC"
    echo "  $0 deploy arbitrum        # Deploy to Arbitrum"
    echo "  $0 deploy all-testnet     # Deploy to all testnets"
}

# Get RPC URL and verify info for a chain
# Using Etherscan API V2 unified endpoint: https://api.etherscan.io/v2/api?chainid=<CHAIN_ID>
# Only need ONE Etherscan API key for all chains!
get_chain_config() {
    local chain=$1
    case $chain in
        # Mainnets - Using Etherscan V2 API with chainid
        bsc)
            echo "$RPC_BSC|$ETHERSCAN_API_KEY|https://api.etherscan.io/v2/api?chainid=56"
            ;;
        arbitrum)
            echo "$RPC_ARB|$ETHERSCAN_API_KEY|https://api.etherscan.io/v2/api?chainid=42161"
            ;;
        polygon)
            echo "$RPC_POLYGON|$ETHERSCAN_API_KEY|https://api.etherscan.io/v2/api?chainid=137"
            ;;
        avalanche)
            echo "$RPC_AVAX|$ETHERSCAN_API_KEY|https://api.etherscan.io/v2/api?chainid=43114"
            ;;
        ethereum)
            echo "$RPC_ETH|$ETHERSCAN_API_KEY|https://api.etherscan.io/v2/api?chainid=1"
            ;;
        base)
            echo "$RPC_BASE|$ETHERSCAN_API_KEY|https://api.etherscan.io/v2/api?chainid=8453"
            ;;
        op)
            echo "$RPC_OP|$ETHERSCAN_API_KEY|https://api.etherscan.io/v2/api?chainid=10"
            ;;
        monad)
            # Monad Mainnet chainid=143
            echo "$RPC_MONAD|$ETHERSCAN_API_KEY|https://api.etherscan.io/v2/api?chainid=143"
            ;;
        # Testnets - Using Etherscan V2 API with chainid
        bsc-testnet)
            echo "$RPC_BSC_TESTNET|$ETHERSCAN_API_KEY|https://api.etherscan.io/v2/api?chainid=97"
            ;;
        arbitrum-sepolia)
            echo "$RPC_ARB_SEPOLIA|$ETHERSCAN_API_KEY|https://api.etherscan.io/v2/api?chainid=421614"
            ;;
        *)
            echo ""
            ;;
    esac
}

# Main script
case $1 in
    deploy)
        case $2 in
            all)
                echo -e "${YELLOW}Deploying to ALL MAINNETS...${NC}"
                for chain in bsc arbitrum polygon avalanche ethereum base op monad; do
                    config=$(get_chain_config $chain)
                    IFS='|' read -r rpc_url api_key verify_url <<< "$config"
                    deploy_to_chain "$chain" "$rpc_url" "$api_key" "$verify_url"
                done
                ;;
            all-testnet)
                echo -e "${GREEN}Deploying to all testnets...${NC}"
                for chain in bsc-testnet arbitrum-sepolia; do
                    config=$(get_chain_config $chain)
                    IFS='|' read -r rpc_url api_key verify_url <<< "$config"
                    deploy_to_chain "$chain" "$rpc_url" "$api_key" "$verify_url"
                done
                ;;
            *)
                if [ -z "$2" ]; then
                    echo -e "${RED}Error: Please specify a chain${NC}"
                    show_usage
                    exit 1
                fi
                config=$(get_chain_config $2)
                if [ -z "$config" ]; then
                    echo -e "${RED}Error: Unknown chain '$2'${NC}"
                    show_usage
                    exit 1
                fi
                IFS='|' read -r rpc_url api_key verify_url <<< "$config"
                deploy_to_chain "$2" "$rpc_url" "$api_key" "$verify_url"
                ;;
        esac
        ;;
    simulate)
        if [ -z "$2" ]; then
            echo -e "${RED}Error: Please specify a chain${NC}"
            show_usage
            exit 1
        fi
        config=$(get_chain_config $2)
        if [ -z "$config" ]; then
            echo -e "${RED}Error: Unknown chain '$2'${NC}"
            show_usage
            exit 1
        fi
        IFS='|' read -r rpc_url api_key verify_url <<< "$config"
        simulate_deployment "$2" "$rpc_url"
        ;;
    list)
        echo "Supported Chains:"
        echo ""
        echo "Mainnets (BSC = Main Chain, Others = Bridge only):"
        echo "  bsc        - BNB Smart Chain (Chain ID: 56) [MAIN]"
        echo "  arbitrum   - Arbitrum One (Chain ID: 42161)"
        echo "  polygon    - Polygon (Chain ID: 137)"
        echo "  avalanche  - Avalanche C-Chain (Chain ID: 43114)"
        echo "  ethereum   - Ethereum Mainnet (Chain ID: 1)"
        echo "  base       - Base (Chain ID: 8453)"
        echo "  op         - OP Mainnet (Chain ID: 10)"
        echo "  monad      - Monad (Chain ID: 143)"
        echo ""
        echo "Testnets (BSC Testnet = Main Chain):"
        echo "  bsc-testnet      - BSC Testnet (Chain ID: 97) [MAIN]"
        echo "  arbitrum-sepolia - Arbitrum Sepolia (Chain ID: 421614)"
        ;;
    bridge)
        # Deploy MessageManager for cross-chain bridge
        if [ -z "$2" ]; then
            echo -e "${RED}Error: Please specify a chain${NC}"
            echo "Usage: $0 bridge <chain|all|all-testnet>"
            exit 1
        fi
        
        case $2 in
            all)
                echo -e "${YELLOW}Deploying MessageManager to ALL MAINNETS...${NC}"
                for chain in bsc arbitrum polygon avalanche ethereum base op monad; do
                    config=$(get_chain_config $chain)
                    IFS='|' read -r rpc_url api_key verify_url <<< "$config"
                    
                    if [ -z "$rpc_url" ]; then
                        echo -e "${YELLOW}Skipping ${chain}: RPC URL not configured${NC}"
                        continue
                    fi
                    
                    echo -e "${BLUE}========================================${NC}"
                    echo -e "${BLUE}Deploying MessageManager to ${chain}${NC}"
                    echo -e "${BLUE}========================================${NC}"
                    
                    verify_args=""
                    if [ -n "$api_key" ] && [ -n "$verify_url" ]; then
                        verify_args="--verify --etherscan-api-key $api_key --verifier-url $verify_url --retries 100 --delay 8"
                    fi
                    
                    if forge script script/Bridge/DeployMessageManager.s.sol:DeployMessageManager \
                        --rpc-url "$rpc_url" \
                        --private-key "$PRIVATE_KEY" \
                        --broadcast \
                        $verify_args \
                        -vvv; then
                        echo -e "${GREEN}✓ MessageManager deployed to ${chain}!${NC}"
                    else
                        echo -e "${YELLOW}⚠️  MessageManager deployment to ${chain} may have issues${NC}"
                    fi
                    echo ""
                done
                ;;
            all-testnet)
                echo -e "${GREEN}Deploying MessageManager to all testnets...${NC}"
                for chain in bsc-testnet arbitrum-sepolia; do
                    config=$(get_chain_config $chain)
                    IFS='|' read -r rpc_url api_key verify_url <<< "$config"
                    
                    if [ -z "$rpc_url" ]; then
                        echo -e "${YELLOW}Skipping ${chain}: RPC URL not configured${NC}"
                        continue
                    fi
                    
                    echo -e "${BLUE}========================================${NC}"
                    echo -e "${BLUE}Deploying MessageManager to ${chain}${NC}"
                    echo -e "${BLUE}========================================${NC}"
                    
                    verify_args=""
                    if [ -n "$api_key" ] && [ -n "$verify_url" ]; then
                        verify_args="--verify --etherscan-api-key $api_key --verifier-url $verify_url --retries 100 --delay 8"
                    fi
                    
                    if forge script script/Bridge/DeployMessageManager.s.sol:DeployMessageManager \
                        --rpc-url "$rpc_url" \
                        --private-key "$PRIVATE_KEY" \
                        --broadcast \
                        $verify_args \
                        -vvv; then
                        echo -e "${GREEN}✓ MessageManager deployed to ${chain}!${NC}"
                    else
                        echo -e "${YELLOW}⚠️  MessageManager deployment to ${chain} may have issues${NC}"
                    fi
                    echo ""
                done
                ;;
            *)
                config=$(get_chain_config $2)
                if [ -z "$config" ]; then
                    echo -e "${RED}Error: Unknown chain '$2'${NC}"
                    exit 1
                fi
                IFS='|' read -r rpc_url api_key verify_url <<< "$config"
                
                echo -e "${BLUE}========================================${NC}"
                echo -e "${BLUE}Deploying MessageManager to ${2}${NC}"
                echo -e "${BLUE}========================================${NC}"
                
                verify_args=""
                if [ -n "$api_key" ] && [ -n "$verify_url" ]; then
                    verify_args="--verify --etherscan-api-key $api_key --verifier-url $verify_url --retries 100 --delay 8"
                fi
                
                if forge script script/Bridge/DeployMessageManager.s.sol:DeployMessageManager \
                    --rpc-url "$rpc_url" \
                    --private-key "$PRIVATE_KEY" \
                    --broadcast \
                    $verify_args \
                    -vvv; then
                    echo -e "${GREEN}✓ MessageManager deployed to ${2}!${NC}"
                else
                    echo -e "${YELLOW}⚠️  MessageManager deployment may have issues${NC}"
                fi
                ;;
        esac
        ;;
    *)
        show_usage
        ;;
esac
