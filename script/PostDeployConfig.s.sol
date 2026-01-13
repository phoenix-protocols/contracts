// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "forge-std/console.sol";

import {Vault} from "src/Vault/Vault.sol";
import {FarmUpgradeable} from "src/Farm/Farm.sol";
import {PUSDOracleUpgradeable} from "src/Oracle/PUSDOracle.sol";
import {ReferralRewardManager} from "src/Referral/ReferralRewardManager.sol";
import {yPUSD} from "src/token/yPUSD/yPUSD.sol";
import {NFTManager} from "src/token/NFTManager/NFTManager.sol";

/**
 * @title PostDeployConfig
 * @notice Post-deployment configuration for Phoenix Protocol
 *
 * ARCHITECTURE:
 *   - BSC (BSC Testnet) = Main Chain → Run "main" config (full configuration)
 *   - Other Chains → Run "bridge" config only (bridge configuration only)
 *   - Supported Assets: USDT, USDC only
 *
 * Usage:
 *   CONFIG_TYPE=main ./post-config.sh bsc-testnet    # BSC main chain full config
 *   CONFIG_TYPE=bridge ./post-config.sh arb-sepolia  # Other chains bridge config only
 */
contract PostDeployConfig is Script {
    // Contract addresses (from .env)
    address public vault;
    address public farm;
    address public oracle;
    address public referralManager;
    address public ypusd;
    address public nftManager;

    // Role addresses (support multiple addresses)
    address public relayer;
    address[] public keepers;
    address[] public operators;

    function run() external {
        // Load deployed addresses
        vault = vm.envAddress("VAULT");
        farm = vm.envAddress("FARM");
        oracle = vm.envAddress("ORACLE");
        referralManager = vm.envOr("REFERRAL_MANAGER", address(0));
        ypusd = vm.envOr("YPUSD", address(0));
        nftManager = vm.envOr("NFT_MANAGER", address(0));

        // Load role addresses (support comma-separated multiple addresses)
        relayer = vm.envOr("RELAYER", address(0));
        keepers = _parseAddresses(vm.envOr("KEEPER", string("")));
        operators = _parseAddresses(vm.envOr("OPERATOR", string("")));

        string memory configType = vm.envOr("CONFIG_TYPE", string("main"));

        console.log("========================================");
        console.log("Phoenix Post-Deploy Configuration");
        console.log("========================================");
        console.log("Chain ID:", block.chainid);
        console.log("Config Type:", configType);
        console.log("");

        if (keccak256(bytes(configType)) == keccak256(bytes("main"))) {
            // BSC / BSC Testnet - 全量配置
            _runMainChainConfig();
        } else if (keccak256(bytes(configType)) == keccak256(bytes("bridge"))) {
            // 其他链 - 只配置跨链
            _runBridgeConfig();
        } else {
            revert("Invalid CONFIG_TYPE. Use: main or bridge");
        }
    }

    // ╔═══════════════════════════════════════════════════════════════════════╗
    // ║                    MAIN CHAIN CONFIG (BSC Only)                        ║
    // ╚═══════════════════════════════════════════════════════════════════════╝
    function _runMainChainConfig() internal {
        console.log(">>> Running MAIN CHAIN configuration...");
        console.log("    (Vault assets, Oracle, Farm params, Bridge)");
        console.log("");

        vm.startBroadcast();

        // 1. Configure Vault Assets (USDT, USDC)
        _configureVaultAssets();

        // 2. Configure Oracle (Bootstrap mode for testnet)
        _configureOracle();

        // 3. Configure Farm Lock Periods
        _configureLockPeriods();

        // 4. Configure Farm APY
        _configureAPY();

        // 5. Configure Fee Rates
        _configureFeeRates();

        // 6. Configure System Config (minDeposit, minLock, maxStakes, etc.)
        _configureSystemConfig();

        // 7. Configure NFTManager (set vault address for transfer exclusion)
        _configureNFTManager();

        // 10. Configure Bridge Chains
        _configureBridgeChains();

        // 11. Configure Roles (BRIDGE_ROLE, etc.)
        _configureRoles();

        vm.stopBroadcast();

        console.log("");
        console.log("=== Main Chain Configuration Complete ===");
    }

    // ╔═══════════════════════════════════════════════════════════════════════╗
    // ║                    BRIDGE CONFIG (Other Chains)                        ║
    // ╚═══════════════════════════════════════════════════════════════════════╝
    function _runBridgeConfig() internal {
        console.log(">>> Running BRIDGE configuration only...");
        console.log("");

        vm.startBroadcast();

        // Configure bridge chains
        _configureBridgeChains();

        // Configure fee rates (bridge fee needed for cross-chain from this chain)
        _configureFeeRates();

        vm.stopBroadcast();

        console.log("");
        console.log("=== Bridge Configuration Complete ===");
    }

    // ════════════════════════════════════════════════════════════════════════
    // VAULT ASSETS - USDT & USDC Only
    // ════════════════════════════════════════════════════════════════════════
    function _configureVaultAssets() internal {
        console.log("--- Configuring Vault Assets (USDT, USDC) ---");

        Vault vaultContract = Vault(vault);

        // Get token addresses based on chain
        address usdt;
        address usdc;

        if (block.chainid == 97) {
            // BSC Testnet
            usdt = vm.envOr("BSC_TESTNET_USDT", address(0));
            usdc = vm.envOr("BSC_TESTNET_USDC", address(0));
        } else if (block.chainid == 56) {
            // BSC Mainnet
            usdt = vm.envOr("BSC_USDT", address(0));
            usdc = vm.envOr("BSC_USDC", address(0));
        } else {
            console.log("WARNING: Unknown chain for Vault assets");
            return;
        }

        if (usdt != address(0)) {
            if (!vaultContract.supportedAssets(usdt)) {
                vaultContract.addAsset(usdt, "Tether USD");
                console.log("  Added USDT:", usdt);
            } else {
                console.log("  USDT already configured, skipped");
            }
        }
        if (usdc != address(0)) {
            if (!vaultContract.supportedAssets(usdc)) {
                vaultContract.addAsset(usdc, "USD Coin");
                console.log("  Added USDC:", usdc);
            } else {
                console.log("  USDC already configured, skipped");
            }
        }
    }

    // ════════════════════════════════════════════════════════════════════════
    // ORACLE - Add Token with Chainlink Feed (Simplified: PUSD/USD = 1)
    // ════════════════════════════════════════════════════════════════════════
    function _configureOracle() internal {
        console.log("--- Configuring Oracle (Simplified Primary Market Design) ---");
        console.log("  PUSD/USD = 1 (constant), only Chainlink feeds for Token/USD");

        PUSDOracleUpgradeable oracleContract = PUSDOracleUpgradeable(oracle);

        address usdt;
        address usdc;
        address usdtFeed;
        address usdcFeed;

        if (block.chainid == 97) {
            // BSC Testnet
            usdt = vm.envOr("BSC_TESTNET_USDT", address(0));
            usdc = vm.envOr("BSC_TESTNET_USDC", address(0));
            usdtFeed = vm.envOr("BSC_TESTNET_FEED_USDT_USD", address(0));
            usdcFeed = vm.envOr("BSC_TESTNET_FEED_USDC_USD", address(0));
        } else if (block.chainid == 56) {
            // BSC Mainnet
            usdt = vm.envOr("BSC_USDT", address(0));
            usdc = vm.envOr("BSC_USDC", address(0));
            usdtFeed = vm.envOr("BSC_FEED_USDT_USD", address(0));
            usdcFeed = vm.envOr("BSC_FEED_USDC_USD", address(0));
        } else {
            console.log("  WARNING: Unknown chain, skipping Oracle config");
            return;
        }

        // Add tokens with Chainlink feeds and max price age
        // Stablecoins use 24h (Chainlink heartbeat is typically 24h for stablecoins)
        uint256 stablecoinMaxPriceAge = 3600 * 25; // 25 hours (with buffer)

        if (usdt != address(0) && usdtFeed != address(0)) {
            (address existingFeed, ) = oracleContract.tokens(usdt);
            if (existingFeed == address(0)) {
                oracleContract.addToken(usdt, usdtFeed, stablecoinMaxPriceAge);
                console.log("  Added USDT with Chainlink feed:", usdtFeed);
            } else {
                console.log("  USDT Oracle already configured, skipped");
            }
        }

        if (usdc != address(0) && usdcFeed != address(0)) {
            (address existingFeed, ) = oracleContract.tokens(usdc);
            if (existingFeed == address(0)) {
                oracleContract.addToken(usdc, usdcFeed, stablecoinMaxPriceAge);
                console.log("  Added USDC with Chainlink feed:", usdcFeed);
            } else {
                console.log("  USDC Oracle already configured, skipped");
            }
        }

        // Send initial heartbeat to Vault (CRITICAL for deposits/withdrawals to work)
        oracleContract.sendHeartbeat();
        console.log("  Initial heartbeat sent to Vault");
    }

    // ════════════════════════════════════════════════════════════════════════
    // FARM - Lock Periods
    // ════════════════════════════════════════════════════════════════════════
    function _configureLockPeriods() internal {
        console.log("--- Configuring Lock Periods ---");

        FarmUpgradeable farmContract = FarmUpgradeable(farm);

        uint256[] memory lockPeriods = new uint256[](4);
        uint16[] memory multipliers = new uint16[](4);

        // Read from .env with defaults
        uint16 mult7d = uint16(vm.envOr("LOCK_7D_MULT", uint256(10000)));
        uint16 mult31d = uint16(vm.envOr("LOCK_31D_MULT", uint256(12000)));
        uint16 mult89d = uint16(vm.envOr("LOCK_89D_MULT", uint256(15000)));
        uint16 mult181d = uint16(vm.envOr("LOCK_181D_MULT", uint256(20000)));

        // 7 days
        lockPeriods[0] = 7 days;
        multipliers[0] = mult7d;

        // 31 days
        lockPeriods[1] = 31 days;
        multipliers[1] = mult31d;

        // 89 days
        lockPeriods[2] = 89 days;
        multipliers[2] = mult89d;

        // 181 days
        lockPeriods[3] = 181 days;
        multipliers[3] = mult181d;
        // Pool caps from .env (0 = no limit)
        uint256[] memory caps = new uint256[](4);
        caps[0] = vm.envOr("LOCK_7D_CAP", uint256(0));
        caps[1] = vm.envOr("LOCK_31D_CAP", uint256(0));
        caps[2] = vm.envOr("LOCK_89D_CAP", uint256(0));
        caps[3] = vm.envOr("LOCK_181D_CAP", uint256(0));

        farmContract.batchSetLockPeriodConfig(lockPeriods, multipliers, caps);

        console.log("  7d:", mult7d, "x, cap:", caps[0]);
        console.log("  31d:", mult31d, "x, cap:", caps[1]);
        console.log("  89d:", mult89d, "x, cap:", caps[2]);
        console.log("  181d:", mult181d, "x, cap:", caps[3]);
    }

    // ════════════════════════════════════════════════════════════════════════
    // FARM - APY
    // ════════════════════════════════════════════════════════════════════════
    function _configureAPY() internal {
        console.log("--- Configuring APY ---");

        FarmUpgradeable farmContract = FarmUpgradeable(farm);

        uint256 baseAPY = vm.envOr("BASE_APY", uint256(1321)); // Default 13.21%
        farmContract.setAPY(baseAPY);

        console.log("  Base APY:", baseAPY, "bps");
    }

    // ════════════════════════════════════════════════════════════════════════
    // FARM - Fee Rates
    // ════════════════════════════════════════════════════════════════════════
    function _configureFeeRates() internal {
        console.log("--- Configuring Fee Rates ---");

        FarmUpgradeable farmContract = FarmUpgradeable(farm);

        uint256 depositFee = vm.envOr("FEE_DEPOSIT", uint256(0));
        uint256 withdrawFee = vm.envOr("FEE_WITHDRAW", uint256(50));
        uint256 bridgeFee = vm.envOr("FEE_BRIDGE", uint256(10));

        farmContract.setFeeRates(depositFee, withdrawFee, bridgeFee);

        console.log("  Deposit:", depositFee, "bps");
        console.log("  Withdraw:", withdrawFee, "bps");
        console.log("  Bridge:", bridgeFee, "bps");
    }

    // ════════════════════════════════════════════════════════════════════════
    // FARM - System Config (minDeposit, minLock, maxStakes, maxAPYHistory)
    // ════════════════════════════════════════════════════════════════════════
    function _configureSystemConfig() internal {
        console.log("--- Configuring System Config ---");

        FarmUpgradeable farmContract = FarmUpgradeable(farm);

        // configType 0: minDepositAmount (PUSD wei, e.g., 10 PUSD = 10000000)
        uint256 minDeposit = vm.envOr("MIN_DEPOSIT", uint256(0));
        if (minDeposit > 0) {
            farmContract.updateSystemConfig(0, minDeposit);
            console.log("  minDepositAmount:", minDeposit, "wei");
        }

        // configType 1: minLockAmount (PUSD wei, e.g., 100 PUSD = 100000000)
        uint256 minLock = vm.envOr("MIN_LOCK", uint256(0));
        if (minLock > 0) {
            farmContract.updateSystemConfig(1, minLock);
            console.log("  minLockAmount:", minLock, "wei");
        }

        // configType 2: maxStakesPerUser (10-65535)
        uint256 maxStakes = vm.envOr("MAX_STAKES_PER_USER", uint256(0));
        if (maxStakes > 0) {
            farmContract.updateSystemConfig(2, maxStakes);
            console.log("  maxStakesPerUser:", maxStakes);
        }

        // configType 3: maxAPYHistory (50-65535)
        uint256 maxAPYHistory = vm.envOr("MAX_APY_HISTORY", uint256(0));
        if (maxAPYHistory > 0) {
            farmContract.updateSystemConfig(3, maxAPYHistory);
            console.log("  maxAPYHistory:", maxAPYHistory);
        }
    }

    // ════════════════════════════════════════════════════════════════════════
    // ════════════════════════════════════════════════════════════════════════
    // NFTMANAGER - Set Vault Address for Transfer Exclusion    // ════════════════════════════════════════════════════════════════════════
    function _configureNFTManager() internal {
        console.log("--- Configuring NFTManager ---");

        if (nftManager == address(0)) {
            console.log("  WARNING: NFT_MANAGER not set, skipping");
            return;
        }

        NFTManager nftManagerContract = NFTManager(nftManager);

        // Set vault address so NFT transfers to/from vault (for lending collateral)
        // are excluded from Farm tokenIds sync
        if (vault != address(0)) {
            nftManagerContract.setVault(vault);
            console.log("  Vault set to:", vault);
        } else {
            console.log("  WARNING: VAULT not set!");
        }
    }

    // ════════════════════════════════════════════════════════════════════════
    // BRIDGE - Supported Chains (8 chains)
    // ════════════════════════════════════════════════════════════════════════
    function _configureBridgeChains() internal {
        console.log("--- Configuring Bridge Chains ---");

        FarmUpgradeable farmContract = FarmUpgradeable(farm);

        uint256[] memory chainIds;
        bool[] memory supported;

        // Determine chains based on network
        if (block.chainid == 97 || block.chainid == 421614) {
            // Testnet: BSC Testnet <-> Arbitrum Sepolia
            chainIds = new uint256[](2);
            supported = new bool[](2);

            chainIds[0] = 97; // BSC Testnet
            chainIds[1] = 421614; // Arbitrum Sepolia
            supported[0] = true;
            supported[1] = true;

            console.log("  BSC Testnet (97): enabled");
            console.log("  Arbitrum Sepolia (421614): enabled");
        } else {
            // Mainnet: 8 chains supported
            chainIds = new uint256[](8);
            supported = new bool[](8);

            chainIds[0] = 56; // BSC
            chainIds[1] = 42161; // Arbitrum One
            chainIds[2] = 1; // Ethereum
            chainIds[3] = 137; // Polygon
            chainIds[4] = 43114; // Avalanche
            chainIds[5] = 10; // Optimism
            chainIds[6] = 8453; // Base
            chainIds[7] = 143; // Monad

            for (uint256 i = 0; i < 8; i++) {
                supported[i] = true;
            }

            console.log("  BSC (56): enabled");
            console.log("  Arbitrum One (42161): enabled");
            console.log("  Ethereum (1): enabled");
            console.log("  Polygon (137): enabled");
            console.log("  Avalanche (43114): enabled");
            console.log("  Optimism (10): enabled");
            console.log("  Base (8453): enabled");
            console.log("  Monad (143): enabled");
        }

        farmContract.setSupportedBridgeChain(chainIds, supported);

        // Set bridge messenger if provided
        address bridgeMessenger = vm.envOr("BRIDGE_MESSENGER", address(0));
        if (bridgeMessenger != address(0)) {
            farmContract.setBridgeMessenger(bridgeMessenger);
            console.log("  Bridge Messenger:", bridgeMessenger);
        } else {
            console.log("  WARNING: Bridge messenger not set");
        }
    }

    // ════════════════════════════════════════════════════════════════════════
    // ROLES - Grant roles to Relayer and other addresses
    // ════════════════════════════════════════════════════════════════════════
    function _configureRoles() internal {
        console.log("--- Configuring Roles ---");

        if (relayer == address(0)) {
            console.log("  WARNING: RELAYER not set, skipping role config");
            return;
        }

        // 1. Farm: Grant BRIDGE_ROLE to relayer (for bridgeFinalizedPUSD)
        FarmUpgradeable farmContract = FarmUpgradeable(farm);
        bytes32 bridgeRole = keccak256("BRIDGE_ROLE");
        if (!farmContract.hasRole(bridgeRole, relayer)) {
            farmContract.grantRole(bridgeRole, relayer);
            console.log("  Farm.BRIDGE_ROLE granted to relayer:", relayer);
        } else {
            console.log("  Farm.BRIDGE_ROLE already granted to relayer");
        }

        // 2. ReferralManager: Grant REWARD_MANAGER_ROLE to Relayer
        if (referralManager != address(0)) {
            ReferralRewardManager refContract = ReferralRewardManager(referralManager);
            bytes32 rewardManagerRole = keccak256("REWARD_MANAGER_ROLE");
            if (!refContract.hasRole(rewardManagerRole, relayer)) {
                refContract.grantRole(rewardManagerRole, relayer);
                console.log("  ReferralManager.REWARD_MANAGER_ROLE granted to relayer:", relayer);
            } else {
                console.log("  ReferralManager.REWARD_MANAGER_ROLE already granted to relayer");
            }
        }

        // 3. yPUSD: Grant YIELD_INJECTOR_ROLE to keepers (for accrueYield)
        if (ypusd != address(0) && keepers.length > 0) {
            yPUSD ypusdContract = yPUSD(ypusd);
            bytes32 yieldInjectorRole = keccak256("YIELD_INJECTOR_ROLE");
            for (uint256 i = 0; i < keepers.length; i++) {
                if (!ypusdContract.hasRole(yieldInjectorRole, keepers[i])) {
                    ypusdContract.grantRole(yieldInjectorRole, keepers[i]);
                    console.log("  yPUSD.YIELD_INJECTOR_ROLE granted to keeper:", keepers[i]);
                } else {
                    console.log("  yPUSD.YIELD_INJECTOR_ROLE already granted to keeper:", keepers[i]);
                }
            }
        } else {
            if (ypusd == address(0)) console.log("  WARNING: YPUSD not set, skipping YIELD_INJECTOR_ROLE");
            if (keepers.length == 0) console.log("  WARNING: KEEPER not set, skipping YIELD_INJECTOR_ROLE");
        }

        // 4. Vault: Grant PAUSER_ROLE to Oracle (for depeg auto-pause)
        Vault vaultContract = Vault(vault);
        bytes32 pauserRole = keccak256("PAUSER_ROLE");
        if (!vaultContract.hasRole(pauserRole, oracle)) {
            vaultContract.grantRole(pauserRole, oracle);
            console.log("  Vault.PAUSER_ROLE granted to Oracle:", oracle);
        } else {
            console.log("  Vault.PAUSER_ROLE already granted to Oracle");
        }

        // 5. Farm: Grant OPERATOR_ROLE to operators (for APY/fees/configuration)
        if (operators.length > 0) {
            bytes32 operatorRole = keccak256("OPERATOR_ROLE");
            for (uint256 i = 0; i < operators.length; i++) {
                if (!farmContract.hasRole(operatorRole, operators[i])) {
                    farmContract.grantRole(operatorRole, operators[i]);
                    console.log("  Farm.OPERATOR_ROLE granted to operator:", operators[i]);
                } else {
                    console.log("  Farm.OPERATOR_ROLE already granted to operator:", operators[i]);
                }
            }
        } else {
            console.log("  WARNING: OPERATOR not set, skipping OPERATOR_ROLE");
        }
    }

    // ╔═══════════════════════════════════════════════════════════════════════╗
    // ║                    ADDRESS PARSING HELPER                              ║
    // ╚═══════════════════════════════════════════════════════════════════════╝
    
    /**
     * @notice Parse comma-separated addresses from env string
     * @param envValue The env value like "0x123...,0x456...,0x789..."
     * @return addresses Array of parsed addresses
     */
    function _parseAddresses(string memory envValue) internal pure returns (address[] memory) {
        bytes memory b = bytes(envValue);
        if (b.length == 0) {
            return new address[](0);
        }
        
        // Count commas to determine array size
        uint256 count = 1;
        for (uint256 i = 0; i < b.length; i++) {
            if (b[i] == ",") count++;
        }
        
        address[] memory addresses = new address[](count);
        uint256 index = 0;
        uint256 start = 0;
        
        for (uint256 i = 0; i <= b.length; i++) {
            if (i == b.length || b[i] == ",") {
                // Extract substring
                bytes memory addrBytes = new bytes(i - start);
                for (uint256 j = start; j < i; j++) {
                    addrBytes[j - start] = b[j];
                }
                addresses[index] = _parseAddress(string(addrBytes));
                index++;
                start = i + 1;
            }
        }
        
        return addresses;
    }
    
    /**
     * @notice Parse a single hex address string to address
     * @param s The hex string like "0x123..." (42 chars)
     */
    function _parseAddress(string memory s) internal pure returns (address) {
        bytes memory b = bytes(s);
        require(b.length == 42, "Invalid address length");
        require(b[0] == "0" && b[1] == "x", "Address must start with 0x");
        
        uint160 result = 0;
        for (uint256 i = 2; i < 42; i++) {
            result *= 16;
            uint8 c = uint8(b[i]);
            if (c >= 48 && c <= 57) {
                result += c - 48;  // 0-9
            } else if (c >= 65 && c <= 70) {
                result += c - 55;  // A-F
            } else if (c >= 97 && c <= 102) {
                result += c - 87;  // a-f
            } else {
                revert("Invalid hex character");
            }
        }
        return address(result);
    }
}
