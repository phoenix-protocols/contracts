// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "forge-std/console.sol";

import {Vault} from "src/Vault/Vault.sol";
import {FarmUpgradeable} from "src/Farm/Farm.sol";
import {FarmLend} from "src/Farm/FarmLend.sol";
import {PUSDOracleUpgradeable} from "src/Oracle/PUSDOracle.sol";
import {ReferralRewardManager} from "src/Referral/ReferralRewardManager.sol";
import {yPUSD} from "src/token/yPUSD/yPUSD.sol";

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
    address public farmLend;
    address public oracle;
    address public referralManager;
    address public ypusd;

    // Role addresses
    address public relayer;
    address public keeper;
    address public operator;

    function run() external {
        // Load deployed addresses
        vault = vm.envAddress("VAULT");
        farm = vm.envAddress("FARM");
        farmLend = vm.envOr("FARM_LEND", address(0));
        oracle = vm.envAddress("ORACLE");
        referralManager = vm.envOr("REFERRAL_MANAGER", address(0));
        ypusd = vm.envOr("YPUSD", address(0));

        // Load role addresses
        relayer = vm.envOr("RELAYER", address(0));
        keeper = vm.envOr("KEEPER", address(0));
        operator = vm.envOr("OPERATOR", address(0));

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

        // 6. Configure FarmLend Address in Farm
        _configureFarmLend();

        // 7. Configure FarmLend Parameters (allowed debt tokens, ratios)
        _configureFarmLendParams();

        // 8. Configure Bridge Chains
        _configureBridgeChains();

        // 9. Configure Roles (BRIDGE_ROLE, PRICE_UPDATER_ROLE, etc.)
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

        // Only configure bridge chains
        _configureBridgeChains();

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
            vaultContract.addAsset(usdt, "Tether USD");
            console.log("  Added USDT:", usdt);
        }
        if (usdc != address(0)) {
            vaultContract.addAsset(usdc, "USD Coin");
            console.log("  Added USDC:", usdc);
        }
    }

    // ════════════════════════════════════════════════════════════════════════
    // ORACLE - Add Token + Bootstrap Mode
    // ════════════════════════════════════════════════════════════════════════
    function _configureOracle() internal {
        console.log("--- Configuring Oracle ---");

        PUSDOracleUpgradeable oracleContract = PUSDOracleUpgradeable(oracle);

        // 1. Enable bootstrap mode (1:1 pricing for stablecoins)
        oracleContract.enableBootstrapMode();
        console.log("  Bootstrap mode enabled");

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
            console.log("  WARNING: Unknown chain, skipping Oracle config");
            return;
        }

        // 2. Add bootstrap tokens (for 1:1 pricing)
        if (usdt != address(0)) {
            oracleContract.addBootstrapToken(usdt);
            console.log("  Added USDT to bootstrap:", usdt);
        }
        if (usdc != address(0)) {
            oracleContract.addBootstrapToken(usdc);
            console.log("  Added USDC to bootstrap:", usdc);
        }

        // 3. Add tokens with full oracle config (Chainlink + DEX)
        address usdtFeed;
        address usdcFeed;
        address usdtPusdOracle;
        address usdcPusdOracle;

        if (block.chainid == 97) {
            // BSC Testnet
            usdtFeed = vm.envOr("BSC_TESTNET_FEED_USDT_USD", address(0));
            usdcFeed = vm.envOr("BSC_TESTNET_FEED_USDC_USD", address(0));
            usdtPusdOracle = vm.envOr("BSC_TESTNET_ORACLE_USDT_PUSD", address(0));
            usdcPusdOracle = vm.envOr("BSC_TESTNET_ORACLE_USDC_PUSD", address(0));
        } else if (block.chainid == 56) {
            // BSC Mainnet
            usdtFeed = vm.envOr("BSC_FEED_USDT_USD", address(0));
            usdcFeed = vm.envOr("BSC_FEED_USDC_USD", address(0));
            usdtPusdOracle = vm.envOr("BSC_ORACLE_USDT_PUSD", address(0));
            usdcPusdOracle = vm.envOr("BSC_ORACLE_USDC_PUSD", address(0));
        }

        if (usdt != address(0) && usdtFeed != address(0) && usdtPusdOracle != address(0)) {
            oracleContract.addToken(usdt, usdtFeed, usdtPusdOracle);
            console.log("  Added USDT with Chainlink + DEX oracle");
        }

        if (usdc != address(0) && usdcFeed != address(0) && usdcPusdOracle != address(0)) {
            oracleContract.addToken(usdc, usdcFeed, usdcPusdOracle);
            console.log("  Added USDC with Chainlink + DEX oracle");
        }

        // 4. Send initial heartbeat to Vault (CRITICAL for deposits/withdrawals to work)
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
    // FARM - FarmLend Address
    // ════════════════════════════════════════════════════════════════════════
    function _configureFarmLend() internal {
        console.log("--- Configuring FarmLend Address in Farm ---");

        if (farmLend == address(0)) {
            console.log("  WARNING: FARM_LEND not set, skipping");
            return;
        }

        FarmUpgradeable farmContract = FarmUpgradeable(farm);
        farmContract.setFarmLend(farmLend);

        console.log("  FarmLend:", farmLend);
    }

    // ════════════════════════════════════════════════════════════════════════
    // FARMLEND - Allowed Debt Tokens & Parameters
    // ════════════════════════════════════════════════════════════════════════
    function _configureFarmLendParams() internal {
        console.log("--- Configuring FarmLend Parameters ---");

        if (farmLend == address(0)) {
            console.log("  WARNING: FARM_LEND not set, skipping");
            return;
        }

        FarmLend farmLendContract = FarmLend(farmLend);

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
            console.log("  WARNING: Unknown chain, skipping FarmLend config");
            return;
        }

        // 1. Set allowed debt tokens (tokens that can be borrowed)
        if (usdt != address(0)) {
            farmLendContract.setAllowedDebtToken(usdt, true);
            console.log("  Allowed debt token USDT:", usdt);
        }
        if (usdc != address(0)) {
            farmLendContract.setAllowedDebtToken(usdc, true);
            console.log("  Allowed debt token USDC:", usdc);
        }

        // 2. Set collateral ratios (optional - defaults are set in initialize)
        // Defaults: liquidationRatio=12500 (125%), targetCollateralRatio=13000 (130%)
        uint16 liquidationRatio = uint16(vm.envOr("FARMLEND_LIQUIDATION_RATIO", uint256(12500)));
        uint16 targetCR = uint16(vm.envOr("FARMLEND_TARGET_CR", uint256(13000)));
        farmLendContract.setCollateralRatios(liquidationRatio, targetCR);
        console.log("  Liquidation Ratio:", liquidationRatio, "bps");
        console.log("  Target CR:", targetCR, "bps");

        // 3. Set loan duration interest ratios (optional - defaults set in initialize)
        // Loan periods: 7, 31, 89, 181 days
        uint256 interest7d = vm.envOr("FARMLEND_INTEREST_7D", uint256(30)); // 0.3%
        uint256 interest31d = vm.envOr("FARMLEND_INTEREST_31D", uint256(110)); // 1.1%
        uint256 interest89d = vm.envOr("FARMLEND_INTEREST_89D", uint256(250)); // 2.5%
        uint256 interest181d = vm.envOr("FARMLEND_INTEREST_181D", uint256(450)); // 4.5%
        farmLendContract.setLoanDurationInterestRatios(7 days, interest7d);
        farmLendContract.setLoanDurationInterestRatios(31 days, interest31d);
        farmLendContract.setLoanDurationInterestRatios(89 days, interest89d);
        farmLendContract.setLoanDurationInterestRatios(181 days, interest181d);
        console.log("  Interest 7d:", interest7d, "bps");
        console.log("  Interest 31d:", interest31d, "bps");
        console.log("  Interest 89d:", interest89d, "bps");
        console.log("  Interest 181d:", interest181d, "bps");

        // 4. Set PUSD Oracle (CRITICAL - needed for price feeds)
        if (oracle != address(0)) {
            farmLendContract.setPUSDOracle(oracle);
            console.log("  PUSD Oracle set to:", oracle);
        } else {
            console.log("  WARNING: Oracle not set!");
        }

        // 5. Set penalty ratio (basis points, e.g. 50 = 0.5% per day)
        // Default: 50 bps (0.5% per overdue day)
        uint256 penaltyRatio = vm.envOr("FARMLEND_PENALTY_RATIO", uint256(50));
        farmLendContract.setPenaltyRatio(penaltyRatio);
        console.log("  Penalty Ratio:", penaltyRatio, "bps per day");

        // 6. Set loan grace period (seconds after due date before liquidation)
        // Default: 7 days
        uint256 loanGracePeriod = vm.envOr("FARMLEND_LOAN_GRACE_PERIOD", uint256(7 days));
        farmLendContract.setLoanGracePeriod(loanGracePeriod);
        console.log("  Loan Grace Period:", loanGracePeriod / 1 days, "days");

        // 7. Set penalty grace period (seconds after due date before penalty starts)
        // Default: 3 days (must be <= loanGracePeriod)
        uint256 penaltyGracePeriod = vm.envOr("FARMLEND_PENALTY_GRACE_PERIOD", uint256(3 days));
        farmLendContract.setPenaltyGracePeriod(penaltyGracePeriod);
        console.log("  Penalty Grace Period:", penaltyGracePeriod / 1 days, "days");

        // 8. Set liquidation bonus (basis points, e.g. 300 = 3%)
        // Default: 300 bps (3% bonus for liquidators)
        uint16 liquidationBonus = uint16(vm.envOr("FARMLEND_LIQUIDATION_BONUS", uint256(300)));
        farmLendContract.setLiquidationBonus(liquidationBonus);
        console.log("  Liquidation Bonus:", liquidationBonus, "bps");
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

        // 2. Oracle: Grant PRICE_UPDATER_ROLE to relayer
        PUSDOracleUpgradeable oracleContract = PUSDOracleUpgradeable(oracle);
        bytes32 priceUpdaterRole = keccak256("PRICE_UPDATER_ROLE");
        if (!oracleContract.hasRole(priceUpdaterRole, relayer)) {
            oracleContract.grantRole(priceUpdaterRole, relayer);
            console.log("  Oracle.PRICE_UPDATER_ROLE granted to relayer:", relayer);
        } else {
            console.log("  Oracle.PRICE_UPDATER_ROLE already granted to relayer");
        }

        // 3. ReferralManager: Grant REWARD_MANAGER_ROLE to Relayer
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

        // 4. yPUSD: Grant YIELD_INJECTOR_ROLE to keeper (for accrueYield)
        if (ypusd != address(0) && keeper != address(0)) {
            yPUSD ypusdContract = yPUSD(ypusd);
            bytes32 yieldInjectorRole = keccak256("YIELD_INJECTOR_ROLE");
            if (!ypusdContract.hasRole(yieldInjectorRole, keeper)) {
                ypusdContract.grantRole(yieldInjectorRole, keeper);
                console.log("  yPUSD.YIELD_INJECTOR_ROLE granted to keeper:", keeper);
            } else {
                console.log("  yPUSD.YIELD_INJECTOR_ROLE already granted to keeper");
            }
        } else {
            if (ypusd == address(0)) console.log("  WARNING: YPUSD not set, skipping YIELD_INJECTOR_ROLE");
            if (keeper == address(0)) console.log("  WARNING: KEEPER not set, skipping YIELD_INJECTOR_ROLE");
        }

        // 5. Vault: Grant PAUSER_ROLE to Oracle (for depeg auto-pause)
        Vault vaultContract = Vault(vault);
        bytes32 pauserRole = keccak256("PAUSER_ROLE");
        if (!vaultContract.hasRole(pauserRole, oracle)) {
            vaultContract.grantRole(pauserRole, oracle);
            console.log("  Vault.PAUSER_ROLE granted to Oracle:", oracle);
        } else {
            console.log("  Vault.PAUSER_ROLE already granted to Oracle");
        }

        // 6. Farm: Grant OPERATOR_ROLE to operator (for APY/fees/configuration)
        if (operator != address(0)) {
            bytes32 operatorRole = keccak256("OPERATOR_ROLE");
            if (!farmContract.hasRole(operatorRole, operator)) {
                farmContract.grantRole(operatorRole, operator);
                console.log("  Farm.OPERATOR_ROLE granted to operator:", operator);
            } else {
                console.log("  Farm.OPERATOR_ROLE already granted to operator");
            }
        } else {
            console.log("  WARNING: OPERATOR not set, skipping OPERATOR_ROLE");
        }

        // 7. FarmLend: Grant OPERATOR_ROLE to operator (for configuration management)
        if (farmLend != address(0) && operator != address(0)) {
            FarmLend farmLendContract = FarmLend(farmLend);
            bytes32 operatorRole = keccak256("OPERATOR_ROLE");
            if (!farmLendContract.hasRole(operatorRole, operator)) {
                farmLendContract.grantRole(operatorRole, operator);
                console.log("  FarmLend.OPERATOR_ROLE granted to operator:", operator);
            } else {
                console.log("  FarmLend.OPERATOR_ROLE already granted to operator");
            }
        } else {
            if (farmLend == address(0)) console.log("  WARNING: FARMLEND not set, skipping FarmLend OPERATOR_ROLE");
            if (operator == address(0)) console.log("  WARNING: OPERATOR not set, skipping FarmLend OPERATOR_ROLE");
        }
    }
}
