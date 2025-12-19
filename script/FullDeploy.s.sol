// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "forge-std/console.sol";

// Import contracts directly
import {PUSD} from "src/token/PUSD/PUSD.sol";
import {yPUSD} from "src/token/yPUSD/yPUSD.sol";
import {NFTManager} from "src/token/NFTManager/NFTManager.sol";
import {Vault} from "src/Vault/Vault.sol";
import {FarmUpgradeable} from "src/Farm/Farm.sol";
import {FarmLend} from "src/Farm/FarmLend.sol";
import {PUSDOracleUpgradeable} from "src/Oracle/PUSDOracle.sol";
import {ReferralRewardManager} from "src/Referral/ReferralRewardManager.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title FullDeploy
 * @notice Complete deployment script for Phoenix DeFi system with deterministic addresses
 * @dev Uses CREATE2 for both impl and proxy to ensure same addresses across all chains
 * 
 * All contracts will have the SAME address on every EVM chain when using the same SALT
 * 
 * Deployment Order:
 * 1. PUSD Token
 * 2. yPUSD Token (depends on PUSD)
 * 3. NFTManager (with farm=address(0), set later)
 * 4. Vault (depends on PUSD, NFTManager)
 * 5. PUSDOracle (depends on Vault, PUSD)
 * 6. Farm (depends on PUSD, yPUSD, Vault)
 * 7. FarmLend (depends on NFTManager, Vault, PUSDOracle, Farm)
 * 8. ReferralRewardManager (depends on yPUSD)
 */
contract FullDeploy is Script {
    // Deployed contracts
    PUSD public pusd;
    yPUSD public ypusd;
    NFTManager public nftManager;
    Vault public vault;
    FarmUpgradeable public farm;
    FarmLend public farmLend;
    PUSDOracleUpgradeable public oracle;
    ReferralRewardManager public referralManager;

    // Base salt for deterministic deployment
    bytes32 public baseSalt;

    function run() external {
        // Load configuration from environment
        address admin = vm.envAddress("ADMIN");
        uint256 pusdCap = vm.envOr("PUSD_CAP", uint256(1_000_000_000 * 1e6)); // Default 1B PUSD
        uint256 ypusdCap = vm.envOr("YPUSD_CAP", uint256(1_000_000_000 * 1e6)); // Default 1B yPUSD
        string memory nftName = vm.envOr("NFT_NAME", string("Phoenix Stake NFT"));
        string memory nftSymbol = vm.envOr("NFT_SYMBOL", string("pxNFT"));
        baseSalt = vm.envBytes32("SALT");

        console.log("=== Phoenix DeFi Full Deployment (Deterministic) ===");
        console.log("Admin:", admin);
        console.log("Salt:", vm.toString(baseSalt));
        console.log("");

        vm.startBroadcast();

        // ========== Phase 1: Deploy Core Tokens ==========
        console.log("--- Phase 1: Deploying Core Tokens ---");
        
        // 1. Deploy PUSD
        pusd = _deployPUSD(pusdCap, admin);
        console.log("PUSD deployed at:", address(pusd));

        // 2. Deploy yPUSD (depends on PUSD)
        ypusd = _deployYPUSD(address(pusd), ypusdCap, admin);
        console.log("yPUSD deployed at:", address(ypusd));

        // ========== Phase 2: Deploy Infrastructure ==========
        console.log("");
        console.log("--- Phase 2: Deploying Infrastructure ---");

        // 3. Deploy NFTManager (with farm=address(0), will set later)
        nftManager = _deployNFTManager(nftName, nftSymbol, admin, address(0));
        console.log("NFTManager deployed at:", address(nftManager));

        // 4. Deploy Vault (depends on PUSD, NFTManager)
        vault = _deployVault(admin, address(pusd), address(nftManager));
        console.log("Vault deployed at:", address(vault));

        // 5. Deploy PUSDOracle (depends on Vault, PUSD)
        oracle = _deployOracle(address(vault), address(pusd), admin);
        console.log("PUSDOracle deployed at:", address(oracle));

        // ========== Phase 3: Deploy Farm Contracts ==========
        console.log("");
        console.log("--- Phase 3: Deploying Farm Contracts ---");

        // 6. Deploy Farm (depends on PUSD, yPUSD, Vault)
        farm = _deployFarm(admin, address(pusd), address(ypusd), address(vault));
        console.log("Farm deployed at:", address(farm));

        // 7. Deploy FarmLend (depends on NFTManager, Vault, Oracle, Farm)
        farmLend = _deployFarmLend(admin, address(nftManager), address(vault), address(oracle), address(farm));
        console.log("FarmLend deployed at:", address(farmLend));

        // 8. Deploy ReferralRewardManager (depends on yPUSD)
        referralManager = _deployReferral(admin, address(ypusd));
        console.log("ReferralRewardManager deployed at:", address(referralManager));

        // ========== Phase 4: Configure Cross-references ==========
        console.log("");
        console.log("--- Phase 4: Configuring Cross-references ---");

        // NFTManager -> Farm
        nftManager.setFarm(address(farm));
        console.log("NFTManager.setFarm done");

        // Vault -> Farm, FarmLend, Oracle
        vault.setFarmAddress(address(farm));
        console.log("Vault.setFarmAddress done");
        
        vault.setFarmLendAddress(address(farmLend));
        console.log("Vault.setFarmLendAddress done");
        
        vault.setOracleManager(address(oracle));
        console.log("Vault.setOracleManager done");

        // Farm -> NFTManager
        farm.setNFTManager(address(nftManager));
        console.log("Farm.setNFTManager done");

        // Grant MINTER_ROLE to Farm
        pusd.grantRole(pusd.MINTER_ROLE(), address(farm));
        console.log("PUSD.grantRole(MINTER_ROLE, farm) done");
        
        vm.stopBroadcast();

        // ========== Summary ==========
        console.log("");
        console.log("=== Deployment Summary ===");
        console.log("PUSD:           ", address(pusd));
        console.log("yPUSD:          ", address(ypusd));
        console.log("NFTManager:     ", address(nftManager));
        console.log("Vault:          ", address(vault));
        console.log("PUSDOracle:     ", address(oracle));
        console.log("Farm:           ", address(farm));
        console.log("FarmLend:       ", address(farmLend));
        console.log("ReferralManager:", address(referralManager));
        console.log("");
        console.log("=== Post-deployment Actions Required ===");
        console.log("1. Add supported assets to Vault: vault.addAsset(token, minDeposit, maxDeposit)");
        console.log("2. Add tokens to Oracle: oracle.addToken(token, chainlinkFeed, uniswapOracle)");
        console.log("3. For bootstrap (no DEX): oracle.enableBootstrapMode() + oracle.addBootstrapToken(token)");
        console.log("4. Set FarmLend parameters: farmLend.setDebtTokenConfig(...)");
    }

    // ========== Salt Generation ==========
    
    function _implSalt(string memory name) internal view returns (bytes32) {
        return keccak256(abi.encode(baseSalt, name, "impl"));
    }
    
    function _proxySalt(string memory name) internal view returns (bytes32) {
        return keccak256(abi.encode(baseSalt, name, "proxy"));
    }

    // ========== Internal Deploy Functions (all using CREATE2) ==========

    function _deployPUSD(uint256 cap_, address admin_) internal returns (PUSD) {
        // Deploy impl with CREATE2
        bytes32 implSalt = _implSalt("PUSD");
        PUSD impl = new PUSD{salt: implSalt}();
        
        // Deploy proxy with CREATE2
        bytes memory initData = abi.encodeCall(PUSD.initialize, (cap_, admin_));
        bytes32 proxySalt = _proxySalt("PUSD");
        ERC1967Proxy proxy = new ERC1967Proxy{salt: proxySalt}(address(impl), initData);
        
        return PUSD(address(proxy));
    }

    function _deployYPUSD(address pusd_, uint256 cap_, address admin_) internal returns (yPUSD) {
        // Deploy impl with CREATE2
        bytes32 implSalt = _implSalt("yPUSD");
        yPUSD impl = new yPUSD{salt: implSalt}();
        
        // Deploy proxy with CREATE2
        bytes memory initData = abi.encodeCall(yPUSD.initialize, (IERC20(pusd_), cap_, admin_));
        bytes32 proxySalt = _proxySalt("yPUSD");
        ERC1967Proxy proxy = new ERC1967Proxy{salt: proxySalt}(address(impl), initData);
        
        return yPUSD(address(proxy));
    }

    function _deployNFTManager(string memory name_, string memory symbol_, address admin_, address farm_) internal returns (NFTManager) {
        // Deploy impl with CREATE2
        bytes32 implSalt = _implSalt("NFTManager");
        NFTManager impl = new NFTManager{salt: implSalt}();
        
        // Deploy proxy with CREATE2
        bytes memory initData = abi.encodeCall(NFTManager.initialize, (name_, symbol_, admin_, farm_));
        bytes32 proxySalt = _proxySalt("NFTManager");
        ERC1967Proxy proxy = new ERC1967Proxy{salt: proxySalt}(address(impl), initData);
        
        return NFTManager(address(proxy));
    }

    function _deployVault(address admin_, address pusd_, address nftManager_) internal returns (Vault) {
        // Deploy impl with CREATE2
        bytes32 implSalt = _implSalt("Vault");
        Vault impl = new Vault{salt: implSalt}();
        
        // Deploy proxy with CREATE2
        bytes memory initData = abi.encodeCall(Vault.initialize, (admin_, pusd_, nftManager_));
        bytes32 proxySalt = _proxySalt("Vault");
        ERC1967Proxy proxy = new ERC1967Proxy{salt: proxySalt}(address(impl), initData);
        
        return Vault(address(proxy));
    }

    function _deployOracle(address vault_, address pusd_, address admin_) internal returns (PUSDOracleUpgradeable) {
        // Deploy impl with CREATE2
        bytes32 implSalt = _implSalt("Oracle");
        PUSDOracleUpgradeable impl = new PUSDOracleUpgradeable{salt: implSalt}();
        
        // Deploy proxy with CREATE2
        bytes memory initData = abi.encodeCall(PUSDOracleUpgradeable.initialize, (vault_, pusd_, admin_));
        bytes32 proxySalt = _proxySalt("Oracle");
        ERC1967Proxy proxy = new ERC1967Proxy{salt: proxySalt}(address(impl), initData);
        
        return PUSDOracleUpgradeable(address(proxy));
    }

    function _deployFarm(address admin_, address pusd_, address ypusd_, address vault_) internal returns (FarmUpgradeable) {
        // Deploy impl with CREATE2
        bytes32 implSalt = _implSalt("Farm");
        FarmUpgradeable impl = new FarmUpgradeable{salt: implSalt}();
        
        // Deploy proxy with CREATE2
        bytes memory initData = abi.encodeCall(FarmUpgradeable.initialize, (admin_, pusd_, ypusd_, vault_));
        bytes32 proxySalt = _proxySalt("Farm");
        ERC1967Proxy proxy = new ERC1967Proxy{salt: proxySalt}(address(impl), initData);
        
        return FarmUpgradeable(address(proxy));
    }

    function _deployFarmLend(address admin_, address nftManager_, address vault_, address oracle_, address farm_) internal returns (FarmLend) {
        // Deploy impl with CREATE2
        bytes32 implSalt = _implSalt("FarmLend");
        FarmLend impl = new FarmLend{salt: implSalt}();
        
        // Deploy proxy with CREATE2
        bytes memory initData = abi.encodeCall(FarmLend.initialize, (admin_, nftManager_, vault_, oracle_, farm_));
        bytes32 proxySalt = _proxySalt("FarmLend");
        ERC1967Proxy proxy = new ERC1967Proxy{salt: proxySalt}(address(impl), initData);
        
        return FarmLend(address(proxy));
    }

    function _deployReferral(address admin_, address ypusd_) internal returns (ReferralRewardManager) {
        // Deploy impl with CREATE2
        bytes32 implSalt = _implSalt("Referral");
        ReferralRewardManager impl = new ReferralRewardManager{salt: implSalt}();
        
        // Deploy proxy with CREATE2
        bytes memory initData = abi.encodeCall(ReferralRewardManager.initialize, (admin_, ypusd_));
        bytes32 proxySalt = _proxySalt("Referral");
        ERC1967Proxy proxy = new ERC1967Proxy{salt: proxySalt}(address(impl), initData);
        
        return ReferralRewardManager(address(proxy));
    }
}
