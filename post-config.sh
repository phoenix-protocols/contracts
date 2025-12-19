#!/bin/bash

# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║              Phoenix Protocol - Post-Deploy Configuration                  ║
# ╚═══════════════════════════════════════════════════════════════════════════╝
#
# 用法:
#   ./post-config.sh <chain> <config-type>
#
# 测试网:
#   ./post-config.sh bsc-testnet main         # BSC测试网 - 全量配置(主链)
#   ./post-config.sh arbitrum-sepolia bridge  # Arb测试网 - 只配跨链
#
# 主网:
#   ./post-config.sh bsc main                 # BSC主网 - 全量配置(主链)
#   ./post-config.sh arbitrum bridge          # Arbitrum - 只配跨链
#   ./post-config.sh polygon bridge           # Polygon - 只配跨链
#   ... (其他链同理)
#
# ════════════════════════════════════════════════════════════════════════════

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Load .env
if [ ! -f .env ]; then
    echo -e "${RED}Error: .env not found${NC}"
    exit 1
fi
source .env

# Get chain RPC config
get_rpc() {
    case $1 in
        # Testnet
        bsc-testnet)      echo "$RPC_BSC_TESTNET" ;;
        arbitrum-sepolia) echo "$RPC_ARB_SEPOLIA" ;;
        # Mainnet
        bsc)       echo "$RPC_BSC" ;;
        arbitrum)  echo "$RPC_ARB" ;;
        polygon)   echo "$RPC_POLYGON" ;;
        avalanche) echo "$RPC_AVAX" ;;
        ethereum)  echo "$RPC_ETH" ;;
        base)      echo "$RPC_BASE" ;;
        op)        echo "$RPC_OP" ;;
        monad)     echo "$RPC_MONAD" ;;
        *) echo "" ;;
    esac
}

# Validate args
CHAIN=$1
CONFIG_TYPE=$2

if [ -z "$CHAIN" ] || [ -z "$CONFIG_TYPE" ]; then
    echo -e "${YELLOW}Phoenix Post-Deploy Configuration${NC}"
    echo ""
    echo "用法: $0 <chain> <config-type>"
    echo ""
    echo "Config Types:"
    echo "  main   - 全量配置 (只在 BSC/BSC Testnet 主链运行)"
    echo "  bridge - PUSD跨链配置 (所有链都要运行)"
    echo ""
    echo "测试网:"
    echo "  $0 bsc-testnet main           # 先配置主链"
    echo "  $0 arbitrum-sepolia bridge    # 再配置跨链"
    echo ""
    echo "主网:"
    echo "  $0 bsc main                   # 先配置主链"
    echo "  $0 arbitrum bridge            # 配置各跨链"
    echo "  $0 polygon bridge"
    echo "  $0 avalanche bridge"
    echo "  $0 ethereum bridge"
    echo "  $0 base bridge"
    echo "  $0 op bridge"
    echo "  $0 monad bridge"
    exit 1
fi

RPC_URL=$(get_rpc $CHAIN)
if [ -z "$RPC_URL" ]; then
    echo -e "${RED}Error: Unknown chain '$CHAIN'${NC}"
    exit 1
fi

if [[ "$CONFIG_TYPE" != "main" && "$CONFIG_TYPE" != "bridge" ]]; then
    echo -e "${RED}Error: config-type must be 'main' or 'bridge'${NC}"
    exit 1
fi

# Warn if running main config on non-BSC chain
if [[ "$CONFIG_TYPE" == "main" && "$CHAIN" != "bsc" && "$CHAIN" != "bsc-testnet" ]]; then
    echo -e "${YELLOW}  Warning: 'main' config should only run on BSC (main chain)${NC}"
    echo -e "${YELLOW}   Other chains only need 'bridge' config${NC}"
    read -p "Continue anyway? [y/N] " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 1
    fi
fi

# Export for forge script
export CONFIG_TYPE

echo ""
echo -e "${GREEN}╔════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║   Phoenix Post-Deploy Configuration    ║${NC}"
echo -e "${GREEN}╚════════════════════════════════════════╝${NC}"
echo ""
echo "Chain:       $CHAIN"
echo "Config Type: $CONFIG_TYPE"
echo "RPC:         $RPC_URL"
echo ""

# Run forge script
forge script script/PostDeployConfig.s.sol:PostDeployConfig \
    --rpc-url "$RPC_URL" \
    --private-key "$PRIVATE_KEY" \
    --broadcast \
    -vvvv

echo ""
echo -e "${GREEN} Configuration Complete!${NC}"
