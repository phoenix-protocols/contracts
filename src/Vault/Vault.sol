// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import "../interfaces/IPUSDOracle.sol";
import "./VaultStorage.sol";
import "../token/NFTManager/NFTManager.sol";

/**
 * @title VaultUpgradeable
 * @notice Core assetToken vault contract of Phoenix DeFi system
 * @dev Upgradeable multi-assetToken vault supporting dynamic addition/removal of stablecoin assetTokens
 *
 * Main features:
 * - Multi-assetToken support (USDT, USDC and other stablecoins)
 * - Fund deposit/withdrawal management (only callable by Farm contract)
 * - Fee collection and distribution
 * - 48-hour timelock secure withdrawal mechanism
 * - Oracle system health check
 * - Emergency pause functionality
 * - UUPS upgradeable proxy pattern
 *
 * securityfeatures：
 * - Multiple permissions control (admin, assetToken admin, pauser)
 * - Reentrancy attack protection
 * - Timelock large amount withdrawal protection
 * - Oracle offline detection and automatic pause
 */
contract Vault is Initializable, AccessControlUpgradeable, PausableUpgradeable, ReentrancyGuardUpgradeable, UUPSUpgradeable, VaultStorage {
    using SafeERC20 for IERC20;

    /* ========== Constructor and Initialization ========== */

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initialize vault contract
     * @dev Can only be called once, sets admin and assigns initial roles
     *      Assets like USDT and USDC need to be manually added after deployment via addAsset()
     * @param admin Admin address, will receive all management permissions
     * @param _pusdToken PUSD token contract address (for protection, prohibited from being added as collateral)
     */
    function initialize(address admin, address _pusdToken, address nftManager_) public initializer {
        require(admin != address(0), "Vault: Invalid admin address");
        require(_pusdToken != address(0), "Vault: Invalid PUSD address");

        __AccessControl_init();
        __Pausable_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, admin); // Highest management permissions
        _grantRole(PAUSER_ROLE, admin); // Pause permissions
        _grantRole(ASSET_MANAGER_ROLE, admin); // Asset management permissions
        lastHealthCheck = block.timestamp; // Initialize health check time

        // Set PUSD token address (for protection)
        pusdToken = _pusdToken;

        _nftManager = nftManager_;

        // Initialize single admin
        singleAdmin = admin;

        // Note: USDT and USDC assetTokens need to be manually added after deployment
        // Use addAsset() function to add supported assetTokens
    }

    /* ========== System configuration functions ========== */

    /**
     * @notice Set Farm contract address
     * @dev Can only be set once to ensure system security
     * @param _farm Farm contract address
     */
    function setFarmAddress(address _farm) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(farm == address(0), "Vault: Farm address already set");
        require(_farm != address(0), "Vault: Invalid farm address");
        farm = _farm;
        emit FarmAddressSet(_farm);
    }

    /**
     * @notice Set FarmLend contract address
     * @dev Can only be set once to ensure system security
     * @param _farmLend FarmLend contract address
     */
    function setFarmLendAddress(address _farmLend) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(farmLend == address(0), "Vault: FarmLend address already set");
        require(_farmLend != address(0), "Vault: Invalid FarmLend address");
        farmLend = _farmLend;
        emit FarmLendAddressSet(_farmLend);
    }

    /**
     * @notice Set Oracle manager contract address
     * @dev Can only be set once, responsible for system health checks and price feeds
     * @param _oracleManager Oracle manager contract address
     */
    function setOracleManager(address _oracleManager) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(oracleManager == address(0), "Vault: Oracle Manager already set");
        require(_oracleManager != address(0), "Vault: Invalid Oracle Manager address");
        oracleManager = _oracleManager;
        emit OracleManagerSet(_oracleManager);
    }

    /* ========== Asset management functions ========== */

    /**
     * @notice Add supported assetToken
     * @dev Asset admin can dynamically add new stablecoin assetTokens
     * @param assetToken Asset contract address
     * @param name Asset name (e.g., "Tether USD", "USD Coin")
     */
    function addAsset(address assetToken, string memory name) external onlyRole(ASSET_MANAGER_ROLE) {
        // 🔒 Security check: PUSD cannot be a collateral assetToken
        require(assetToken != pusdToken, "Vault: PUSD cannot be collateral assetToken");
        _addAssetInternal(assetToken, name);
    }

    /**
     * @notice Internal function: Add assetToken support (no permission check, for initialization use only)
     * @param assetToken Asset contract address
     * @param name Asset name
     */
    function _addAssetInternal(address assetToken, string memory name) internal {
        require(assetToken != address(0), "Vault: Invalid assetToken address");
        require(!supportedAssets[assetToken], "Vault: Asset already supported");
        require(bytes(name).length > 0, "Vault: Asset name cannot be empty");

        supportedAssets[assetToken] = true;
        assetList.push(assetToken);
        assetNames[assetToken] = name;

        emit AssetAdded(assetToken, name);
    }

    /**
     * @notice Remove supported assetToken
     * @dev Use with caution! Can only remove when assetToken balance and fees are both 0
     * @param assetToken Asset contract address to remove
     */
    function removeAsset(address assetToken) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(supportedAssets[assetToken], "Vault: Asset not supported");
        require(accumulatedFees[assetToken] == 0, "Vault: Asset has unclaimed fees");
        require(IERC20(assetToken).balanceOf(address(this)) == 0, "Vault: Asset has balance");

        supportedAssets[assetToken] = false;
        string memory name = assetNames[assetToken];
        delete assetNames[assetToken];

        // Remove from array (using swap-delete method to optimize gas consumption)
        for (uint256 i = 0; i < assetList.length; i++) {
            if (assetList[i] == assetToken) {
                assetList[i] = assetList[assetList.length - 1];
                assetList.pop();
                break;
            }
        }

        emit AssetRemoved(assetToken, name);
    }

    /* ========== Core fund operation functions ========== */

    /**
     * @notice User deposit function
     * @dev Only Farm contract can call, includes Oracle health check
     * @param user Depositing user address
     * @param assetToken Deposit assetToken address
     * @param amount Deposit amount
     */
    function depositFor(address user, address assetToken, uint256 amount) external nonReentrant whenNotPaused {
        require(block.timestamp - lastHealthCheck < HEALTH_CHECK_TIMEOUT, "Vault: Oracle system offline");
        require(msg.sender == farm || msg.sender == farmLend, "Vault: Caller is not the farm or farmLend");
        require(supportedAssets[assetToken], "Vault: Unsupported assetToken");

        // Check allowance amount, provide friendly error message
        uint256 allowance = IERC20(assetToken).allowance(user, address(this));
        require(allowance >= amount, "Vault: Please approve tokens first");

        IERC20(assetToken).safeTransferFrom(user, address(this), amount);
        emit Deposited(user, assetToken, amount);
        emit TVLChanged(assetToken, IERC20(assetToken).balanceOf(address(this)));
    }

    /**
     * @notice User withdrawal function
     * @dev Only Farm contract can call, includes Oracle health check
     * @param user Withdrawing user address
     * @param assetToken Withdrawal assetToken address
     * @param amount Withdrawal amount
     */
    function withdrawTo(address user, address assetToken, uint256 amount) external nonReentrant whenNotPaused {
        require(block.timestamp - lastHealthCheck < HEALTH_CHECK_TIMEOUT, "Vault: Oracle system offline");
        require(msg.sender == farm || msg.sender == farmLend, "Vault: Caller is not the farm or farmLend");
        require(supportedAssets[assetToken], "Vault: Unsupported assetToken");

        IERC20(assetToken).safeTransfer(user, amount);
        emit Withdrawn(user, assetToken, amount);
        emit TVLChanged(assetToken, IERC20(assetToken).balanceOf(address(this)));
    }

    function withdrawPUSDTo(address user, uint256 amount) external nonReentrant whenNotPaused {
        require(block.timestamp - lastHealthCheck < HEALTH_CHECK_TIMEOUT, "Vault: Oracle system offline");
        require(msg.sender == farm, "Vault: Caller is not the farm");

        IERC20(pusdToken).safeTransfer(user, amount);
        emit Withdrawn(user, address(pusdToken), amount);
        emit TVLChanged(address(pusdToken), IERC20(address(pusdToken)).balanceOf(address(this)));
    }

    /* ========== Reward Reserve Management ========== */

    /**
     * @notice Add PUSD to reward reserve
     * @dev Caller must approve Vault contract to spend PUSD first
     * @param amount Amount of PUSD to add
     */
    function addRewardReserve(uint256 amount) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(amount > 0, "Vault: Amount must be > 0");
        uint256 allowance = IERC20(pusdToken).allowance(msg.sender, address(this));
        require(allowance >= amount, "Vault: Please approve PUSD first");
        IERC20(pusdToken).safeTransferFrom(msg.sender, address(this), amount);
        rewardReserve += amount;
        emit RewardReserveAdded(msg.sender, amount, rewardReserve);
    }

    /**
     * @notice Withdraw PUSD from reward reserve (emergency)
     * @param to Recipient address
     * @param amount Amount to withdraw
     */
    function withdrawRewardReserve(address to, uint256 amount) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(to != address(0), "Vault: Invalid recipient");
        require(amount > 0 && amount <= rewardReserve, "Vault: Invalid amount");
        rewardReserve -= amount;
        IERC20(pusdToken).safeTransfer(to, amount);
        emit RewardReserveWithdrawn(to, amount, rewardReserve);
    }

    /**
     * @notice Distribute rewards from reserve to user
     * @dev Only callable by Farm contract
     * @param to Recipient address
     * @param amount Reward amount
     * @return success Whether the reward was distributed
     */
    function distributeReward(address to, uint256 amount) external nonReentrant returns (bool success) {
        require(msg.sender == farm, "Vault: Caller is not the farm");
        if (amount == 0) return true;
        
        if (rewardReserve >= amount) {
            rewardReserve -= amount;
            IERC20(pusdToken).safeTransfer(to, amount);
            emit RewardDistributed(to, amount, rewardReserve);
            return true;
        } else {
            // Emit event for monitoring, reward not distributed
            emit InsufficientRewardReserve(amount, rewardReserve);
            return false;
        }
    }

    /**
     * @notice Get current reward reserve balance
     * @return Current reward reserve amount
     */
    function getRewardReserve() external view returns (uint256) {
        return rewardReserve;
    }

    /**
     * @notice Add fee
     * @dev Called by Farm contract to record transaction fees
     * @param assetToken Fee assetToken address
     * @param amount Fee amount
     */
    function addFee(address assetToken, uint256 amount) external {
        require(msg.sender == farm, "Vault: Caller is not the farm");
        require(supportedAssets[assetToken] || assetToken == pusdToken, "Vault: Unsupported assetToken");
        require(amount > 0, "Vault: Invalid fee amount");
        accumulatedFees[assetToken] += amount;
    }

    /* ========== Admin operation functions ========== */

    /**
     * @notice Withdraw fees
     * @dev Admin can withdraw accumulated fees to specified address
     * @param assetToken Asset contract address to withdraw fees from
     * @param to Fee recipient address
     */
    function claimFees(address assetToken, address to) external onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant {
        require(supportedAssets[assetToken] || assetToken == pusdToken, "Vault: Unsupported assetToken");
        uint256 feesToClaim = accumulatedFees[assetToken];
        require(feesToClaim > 0, "Vault: No fees to claim");

        uint256 balance = IERC20(assetToken).balanceOf(address(this));
        require(balance >= feesToClaim, "Vault: Insufficient balance for fees");

        accumulatedFees[assetToken] = 0;
        IERC20(assetToken).safeTransfer(to, feesToClaim);
        emit FeesClaimed(to, assetToken, feesToClaim);
    }

    /**
     * @notice Propose batch large amount withdrawal
     * @dev Start 48-hour timelock protection mechanism for emergency or large fund allocation
     * @param to Withdrawal target address
     * @param assetTokens Withdrawal assetToken addresses
     * @param amounts Withdrawal amount corresponding to the assetTokens addresses
     */
    function proposeWithdrawal(address to, address[] calldata assetTokens, uint256[] calldata amounts) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(to != address(0), "Vault: Cannot withdraw to zero address");
        require(assetTokens.length > 0, "Vault: Empty assetTokens array");
        require(amounts.length > 0, "Vault: Empty amounts array");
        require(assetTokens.length == amounts.length, "Vault: Assets and amounts length mismatch");
        require(pendingWithdrawalRequests.length == 0, "Vault: Pending withdrawal exists");

        for (uint256 i = 0; i < assetTokens.length; i++) {
            require(supportedAssets[assetTokens[i]], "Vault: Unsupported assetToken");
            require(amounts[i] > 0, "Vault: Amount must be greater than 0");
            require(IERC20(assetTokens[i]).balanceOf(address(this)) >= amounts[i], "Vault: Insufficient funds for proposal");

            // Check duplicate assetToken
            require(!_tempAssetCheck[assetTokens[i]], "Vault: Duplicate assetToken");
            _tempAssetCheck[assetTokens[i]] = true;
        }

        pendingWithdrawalTo = to;
        withdrawalUnlockTime = block.timestamp + TIMELOCK_DELAY;

        // Push withdrawal requests
        for (uint256 i = 0; i < assetTokens.length; i++) {
            pendingWithdrawalRequests.push(WithdrawalRequest({assetToken: assetTokens[i], amount: amounts[i]}));
        }

        emit WithdrawalProposed(to, assetTokens, amounts, withdrawalUnlockTime);
    }

    /**
     * @notice Execute large amount withdrawal
     * @dev Execute withdrawal operation after timelock expires
     */
    function executeWithdrawal() external onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant {
        require(withdrawalUnlockTime > 0, "Vault: No pending withdrawal");
        require(block.timestamp >= withdrawalUnlockTime, "Vault: Timelock has not expired");
        require(pendingWithdrawalRequests.length > 0, "Vault: No pending withdrawal to execute");

        address to = pendingWithdrawalTo;
        uint256 requestCount = pendingWithdrawalRequests.length;

        address[] memory assetTokens = new address[](requestCount);
        uint256[] memory amounts = new uint256[](requestCount);

        // Execute withdrawal
        for (uint256 i = 0; i < requestCount; i++) {
            WithdrawalRequest memory request = pendingWithdrawalRequests[i];

            // Check balance
            uint256 balance = IERC20(request.assetToken).balanceOf(address(this));
            require(balance >= request.amount, "Vault: Insufficient balance at execution");

            assetTokens[i] = request.assetToken;
            amounts[i] = request.amount;

            IERC20(request.assetToken).safeTransfer(to, request.amount);
            emit TVLChanged(request.assetToken, IERC20(request.assetToken).balanceOf(address(this)));
        }

        // Clear mapping _tempAssetCheck
        for (uint256 i = 0; i < requestCount; i++) {
            delete _tempAssetCheck[pendingWithdrawalRequests[i].assetToken];
        }

        // Clear pending withdrawal state
        delete pendingWithdrawalRequests;
        pendingWithdrawalTo = address(0);
        withdrawalUnlockTime = 0;

        emit WithdrawalExecuted(to, assetTokens, amounts);
    }

    /**
     * @notice Cancel pending withdrawal
     * @dev Admin can cancel a pending withdrawal before it unlocks
     */
    function cancelWithdrawal() external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(pendingWithdrawalRequests.length > 0, "Vault: No pending withdrawal");

        uint256 requestCount = pendingWithdrawalRequests.length;

        address[] memory assetTokens = new address[](requestCount);
        uint256[] memory amounts = new uint256[](requestCount);

        for (uint256 i = 0; i < requestCount; i++) {
            assetTokens[i] = pendingWithdrawalRequests[i].assetToken;
            amounts[i] = pendingWithdrawalRequests[i].amount;
        }

        // Clear mapping _tempAssetCheck
        for (uint256 i = 0; i < requestCount; i++) {
            delete _tempAssetCheck[pendingWithdrawalRequests[i].assetToken];
        }

        // Clear pending withdrawal state
        delete pendingWithdrawalRequests;
        pendingWithdrawalTo = address(0);
        withdrawalUnlockTime = 0;

        emit WithdrawalCancelled(msg.sender, assetTokens, amounts);
    }

    /**
     * @notice Emergency rescue for non-supported tokens mistakenly sent to the vault
     * @dev Only for NON-supported assetTokens. Supported assetTokens must use timelock withdrawal.
     */
    function emergencySweep(address token, address to, uint256 amount) external onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant {
        require(token != address(0) && to != address(0), "Vault: Zero address");
        require(!supportedAssets[token], "Vault: Use timelock for supported assetToken");
        require(token != pusdToken, "Vault: Cannot sweep PUSD");
        IERC20(token).safeTransfer(to, amount);
    }

    /* ========== System monitoring and control functions ========== */

    /**
     * @notice Oracle system heartbeat check
     * @dev Oracle manager calls regularly to prove system is functioning normally
     */
    function heartbeat() external {
        require(msg.sender == oracleManager, "Vault: Only Oracle Manager can send heartbeat");
        lastHealthCheck = block.timestamp;
    }

    function withdrawNFT(uint256 tokenId, address to) external onlyRole(DEFAULT_ADMIN_ROLE) {
        NFTManager nftManager = NFTManager(_nftManager);
        require(nftManager.exists(tokenId));
        require(nftManager.ownerOf(tokenId) == address(this));

        IFarm.StakeRecord memory r = nftManager.getStakeRecord(tokenId);
        require(r.active, "NFTManager: stake already withdrawn");
        require(block.timestamp >= r.startTime + r.lockPeriod + MAX_DELAY_PERIOD, "Vault: stake is still locked");

        nftManager.safeTransferFrom(address(this), to, tokenId);

        emit NFTWithdrawn(to, tokenId);
    }

    function releaseNFT(uint256 tokenId, address to) external {
        require(msg.sender == farmLend, "Not From FarmLend");
        NFTManager nftManager = NFTManager(_nftManager);
        require(nftManager.exists(tokenId));
        require(nftManager.ownerOf(tokenId) == address(this));

        nftManager.safeTransferFrom(address(this), to, tokenId);

        emit NFTWithdrawn(to, tokenId);
    }

    function withdrawNFTByFarm(uint256 tokenId, address to) external {
        require(msg.sender == farm, "Not From Farm");
        NFTManager nftManager = NFTManager(_nftManager);
        require(nftManager.exists(tokenId));
        require(nftManager.ownerOf(tokenId) == address(this));

        IFarm.StakeRecord memory r = nftManager.getStakeRecord(tokenId);
        require(r.active, "NFTManager: stake already withdrawn");
        require(block.timestamp >= r.startTime + r.lockPeriod + MAX_DELAY_PERIOD, "Vault: stake is still locked");

        nftManager.safeTransferFrom(address(this), to, tokenId);

        emit NFTWithdrawn(to, tokenId);
    }

    /**
     * @notice Pause contract
     * @dev Pause all deposit/withdrawal operations in emergency
     */
    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    /**
     * @notice Unpause contract
     * @dev Remove pause state and resume normal operations
     */
    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    /* ========== Query functions ========== */

    // 📋 Frontend call format specification:
    //
    // 🔢 Values that need to be divided by assetToken decimals (raw token amount):
    //   - getTVL(address).tvl          → tvl / (10 ** tokenDecimals)
    //   - getFormattedTVL().assetTokenAmount → amount / (10 ** assetTokenDecimals)
    //   - getPUSDMarketCap()           → marketCap / (10 ** pusdDecimals) [PUSD decimals]
    //
    // 💰 USD values that need to be divided by 10^18 (standard 18 decimal places):
    //   - getTVL(address).marketValue   → value / 1e18
    //   - getTotalTVL()                → value / 1e18
    //   - getTotalMarketValue()        → value / 1e18
    //   - getFormattedTVL().usdAmount  → value / 1e18
    //
    // ✅ Final values (no processing needed):
    //   - getFormattedTVL().assetTokenDecimals → use directly
    //   - getFormattedTVL().assetTokenSymbol   → use directly
    //   - getClaimableFees()             → fees / (10 ** tokenDecimals)

    /**
     * @notice Get vault total value locked (TVL) and market value for specific assetToken
     * @param assetToken Asset contract address
     * @return tvl Asset balance in vault (raw amount, needs to be divided by tokenDecimals)
     * @return marketValue Market value of the assetToken (USD denominated, 18 decimal places, needs to be divided by 1e18)
     */
    function getTVL(address assetToken) external view returns (uint256 tvl, uint256 marketValue) {
        require(supportedAssets[assetToken], "Vault: Unsupported assetToken");

        // Get assetToken balance
        tvl = IERC20(assetToken).balanceOf(address(this));

        // If Oracle is set, calculate real market value
        if (oracleManager != address(0)) {
            try IPUSDOracle(oracleManager).getTokenUSDPrice(assetToken) returns (uint256 price, uint256) {
                // Get assetToken decimal places
                uint8 decimals = IERC20Metadata(assetToken).decimals();

                // Calculate market value: tvl * price / (10 ** decimals)
                // price is already 18 decimal USD price, tvl is raw assetToken amount
                marketValue = (tvl * price) / (10 ** decimals);
            } catch {
                // Oracle call failed, use fallback logic
                marketValue = tvl; // Assume 1:1 USD value
            }
        } else {
            // Oracle not set, use fallback logic
            marketValue = tvl; // Assume 1:1 USD value
        }
    }

    /**
     * @notice Get system total TVL (sum of USD market values of all assetTokens)
     * @return totalTVL System total TVL, USD denominated, 18 decimal places (frontend needs to divide by 1e18)
     * @dev Iterate through all supported assetTokens and calculate their total USD value
     */
    function getTotalTVL() external view returns (uint256 totalTVL) {
        for (uint256 i = 0; i < assetList.length; i++) {
            address assetToken = assetList[i];
            try this.getTVL(assetToken) returns (uint256, uint256 marketValue) {
                totalTVL += marketValue;
            } catch {
                // If price retrieval fails for an assetToken, skip that assetToken
                continue;
            }
        }
    }

    /**
     * @notice Get PUSD market capitalization (another representation of total market TVL)
     * @return pusdMarketCap PUSD circulating market cap (raw amount, needs to be divided by pusd decimals)
     * @dev Directly use contract stored pusdToken address for better security and reliability
     */
    function getPUSDMarketCap() external view returns (uint256 pusdMarketCap) {
        require(pusdToken != address(0), "Vault: PUSD token not set");

        uint256 pusdTotalSupply = IERC20(pusdToken).totalSupply();

        if (oracleManager != address(0)) {
            try IPUSDOracle(oracleManager).getPUSDUSDPrice() returns (uint256 pusdPrice, uint256) {
                // PUSD market cap = circulation * PUSD/USD price
                pusdMarketCap = (pusdTotalSupply * pusdPrice) / 1e18;
            } catch {
                // Oracle call failed, assume PUSD=$1.00
                pusdMarketCap = pusdTotalSupply;
            }
        } else {
            // Oracle not set, assume PUSD=$1.00
            pusdMarketCap = pusdTotalSupply;
        }
    }

    /**
     * @notice Get PUSD value corresponding to specified assetToken amount
     * @param assetToken Asset contract address
     * @param amount Asset amount (raw units, including decimal places)
     * @return pusdAmount Corresponding PUSD amount (6 decimal places)
     * @dev Directly obtain Token/PUSD price through Oracle for conversion, transaction fails if price retrieval fails
     */
    function getTokenPUSDValue(address assetToken, uint256 amount) external view returns (uint256 pusdAmount, uint256 referenceTimestamp) {
        require(supportedAssets[assetToken], "Vault: Unsupported assetToken");
        require(amount >= 0, "Vault: Amount must be greater than or equal to 0");
        require(oracleManager != address(0), "Vault: Oracle not set");

        // Must get price from Oracle, fail if no price
        (uint256 tokenPusdPrice, uint256 lastTimestamp) = IPUSDOracle(oracleManager).getTokenPUSDPrice(assetToken);
        require(tokenPusdPrice > 0, "Vault: Invalid token price");

        // Get assetToken decimal places
        uint8 assetTokenDecimals = IERC20Metadata(assetToken).decimals();

        // Calculate PUSD amount: amount * tokenPusdPrice / (10 ** (assetTokenDecimals + 12))
        // tokenPusdPrice is 18 decimal places, amount is raw assetToken amount, result converted to 6 decimal places
        pusdAmount = (amount * tokenPusdPrice) / (10 ** (assetTokenDecimals + 12));
        referenceTimestamp = lastTimestamp;
    }

    /**
     * @notice Convert PUSD amount to corresponding assetToken amount
     * @param assetToken Asset contract address
     * @param pusdAmount PUSD amount (6 decimal places)
     * @return amount Corresponding assetToken amount
     */
    function getPUSDAssetValue(address assetToken, uint256 pusdAmount) external view returns (uint256 amount, uint256 referenceTimestamp) {
        require(supportedAssets[assetToken], "Vault: Unsupported assetToken");
        require(pusdAmount >= 0, "Vault: Amount must be greater than or equal to 0");
        require(oracleManager != address(0), "Vault: Oracle not set");

        // Must get price from Oracle, fail if no price
        (uint256 tokenPusdPrice, uint256 lastTimeStamp) = IPUSDOracle(oracleManager).getTokenPUSDPrice(assetToken);
        require(tokenPusdPrice > 0, "Vault: Invalid token price");

        // Get assetToken decimal places
        uint8 assetTokenDecimals = IERC20Metadata(assetToken).decimals();

        // Calculate assetToken amount: pusdAmount * (10 ** (assetTokenDecimals + 12)) / tokenPusdPrice
        // This is the reverse calculation of getTokenPUSDValue
        amount = (pusdAmount * (10 ** (assetTokenDecimals + 12))) / tokenPusdPrice;
        referenceTimestamp = lastTimeStamp;
    }

    /**
     * @notice Get simplified formatted TVL information (convenient for frontend display)
     * @param assetToken Asset contract address
     * @return assetTokenAmount Asset amount (without decimal places, e.g.: 1000500 represents 1000.5)
     * @return usdAmount USD value (without decimal places, e.g.: 1000500 represents $1000.5)
     * @return assetTokenDecimals Asset decimal places (for frontend formatting display)
     * @return assetTokenSymbol Asset symbol
     * @dev Frontend usage: assetTokenAmount / (10 ** assetTokenDecimals) to get real amount
     *      Frontend usage: usdAmount / 1e18 to get real USD value
     */
    function getFormattedTVL(address assetToken) external view returns (uint256 assetTokenAmount, uint256 usdAmount, uint8 assetTokenDecimals, string memory assetTokenSymbol) {
        require(supportedAssets[assetToken], "Vault: Unsupported assetToken");

        (uint256 tvl, uint256 marketValue) = this.getTVL(assetToken);

        // Get assetToken information
        assetTokenDecimals = IERC20Metadata(assetToken).decimals();
        assetTokenSymbol = IERC20Metadata(assetToken).symbol();

        // Return raw data, let frontend format it
        assetTokenAmount = tvl; // Keep assetToken raw decimal format
        usdAmount = marketValue; // 18 decimal USD value
    }

    /**
     * @notice Get claimable fees for specific assetToken
     * @param assetToken Asset contract address
     * @return Accumulated fee amount for that assetToken
     */
    function getClaimableFees(address assetToken) external view returns (uint256) {
        require(supportedAssets[assetToken], "Vault: Unsupported assetToken");
        return accumulatedFees[assetToken];
    }

    /**
     * @notice Check system health status
     * @return true if Oracle system is online and functioning normally
     */
    function isHealthy() external view returns (bool) {
        return block.timestamp - lastHealthCheck < HEALTH_CHECK_TIMEOUT;
    }

    /**
     * @notice Check if it's a supported assetToken
     * @param assetToken Asset contract address
     * @return true if the assetToken is supported by the vault
     */
    function isValidAsset(address assetToken) external view returns (bool) {
        return supportedAssets[assetToken];
    }

    /**
     * @notice Get list of all supported assetTokens
     * @return Array of supported assetToken addresses
     */
    function getSupportedAssets() external view returns (address[] memory) {
        return assetList;
    }

    /**
     * @notice Get assetToken name
     * @param assetToken Asset contract address
     * @return Readable name of the assetToken
     */
    function getAssetName(address assetToken) external view returns (string memory) {
        require(supportedAssets[assetToken], "Vault: Unsupported assetToken");
        return assetNames[assetToken];
    }

    /**
     * @notice Get assetToken symbol (abbreviation)
     * @dev Read symbol directly from ERC20 contract
     * @param assetToken Asset contract address
     * @return Asset symbol (e.g., USDT, USDC)
     */
    function getAssetSymbol(address assetToken) external view returns (string memory) {
        require(supportedAssets[assetToken], "Vault: Unsupported assetToken");
        return IERC20Metadata(assetToken).symbol();
    }

    /**
     * @notice Get assetToken decimal places
     * @dev Read decimals directly from ERC20 contract
     * @param assetToken Asset contract address
     * @return Asset decimal places (e.g., 6 for USDT/USDC, 18 for most ERC20)
     */
    function getTokenDecimals(address assetToken) external view returns (uint8) {
        require(supportedAssets[assetToken], "Vault: Unsupported assetToken");
        return IERC20Metadata(assetToken).decimals();
    }

    /**
     * @notice Get remaining time for pending withdrawal
     * @dev Return how many seconds until withdrawal unlock, return 0 if already unlocked
     * @return remainingTime Remaining time (seconds), 0 means ready to execute or no pending withdrawal
     */
    function getRemainingWithdrawalTime() external view returns (uint256 remainingTime) {
        if (pendingWithdrawalRequests.length == 0 || withdrawalUnlockTime == 0) {
            return 0; // No pending withdrawal or unlock time not set
        }

        if (block.timestamp >= withdrawalUnlockTime) {
            return 0; // Already ready to execute
        }

        return withdrawalUnlockTime - block.timestamp; // Remaining seconds
    }

    /**
     * @notice Get pending withdrawal status details
     * @dev Return complete information about current pending withdrawal
     * @return to Withdrawal target address
     * @return assetTokens Withdrawal assetToken addresses
     * @return assetTokenNames Withdrawal assetToken names
     * @return amounts Withdrawal amounts
     * @return unlockTime Unlock timestamp
     * @return remainingTime Remaining time (seconds)
     * @return canExecute Whether it can be executed
     */
    function getPendingWithdrawalInfo() external view returns (address to, address[] memory assetTokens, string[] memory assetTokenNames, uint256[] memory amounts, uint256 unlockTime, uint256 remainingTime, bool canExecute) {
        uint256 requestCount = pendingWithdrawalRequests.length;

        if (requestCount == 0 || withdrawalUnlockTime == 0) {
            return (address(0), new address[](0), new string[](0), new uint256[](0), 0, 0, false);
        }

        to = pendingWithdrawalTo;
        unlockTime = withdrawalUnlockTime;

        assetTokens = new address[](requestCount);
        assetTokenNames = new string[](requestCount);
        amounts = new uint256[](requestCount);

        for (uint256 i = 0; i < requestCount; i++) {
            assetTokens[i] = pendingWithdrawalRequests[i].assetToken;
            amounts[i] = pendingWithdrawalRequests[i].amount;
            assetTokenNames[i] = this.assetNames(assetTokens[i]);
        }

        if (block.timestamp >= unlockTime) {
            remainingTime = 0;
            canExecute = true;
        } else {
            remainingTime = unlockTime - block.timestamp;
            canExecute = false;
        }
    }

    /* ========== Upgrade control functions ========== */

    /**
     * @notice Authorize contract upgrade
     * @dev Only admin can upgrade contract
     * @param newImplementation New implementation contract address
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(DEFAULT_ADMIN_ROLE) {
        // Admin privileges are sufficient, no additional validation needed
    }

    /* ========== Single Admin Management ========== */

    /**
     * @notice Override grantRole function to prevent external DEFAULT_ADMIN_ROLE assignment
     * @dev Force use of transferAdmin() for admin role management
     */
    function grantRole(bytes32 role, address account) public override {
        if (role == DEFAULT_ADMIN_ROLE) {
            revert("Vault: Use transferAdmin() instead");
        }
        super.grantRole(role, account);
    }

    /**
     * @notice Override revokeRole function to prevent external DEFAULT_ADMIN_ROLE revocation
     * @dev Force use of transferAdmin() for admin role management
     */
    function revokeRole(bytes32 role, address account) public override {
        if (role == DEFAULT_ADMIN_ROLE) {
            revert("Vault: Use transferAdmin() instead");
        }
        super.revokeRole(role, account);
    }

    /**
     * @notice Transfer admin role to new address
     * @dev Only current admin can transfer, ensures single admin at all times
     * @param newAdmin New admin address
     */
    function transferAdmin(address newAdmin) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(newAdmin != address(0), "Vault: Invalid admin address");
        require(newAdmin != singleAdmin, "Vault: Already the admin");

        address oldAdmin = singleAdmin;

        super.grantRole(DEFAULT_ADMIN_ROLE, newAdmin);
        singleAdmin = newAdmin;
        // Revoke old admin and grant to new admin
        super.revokeRole(DEFAULT_ADMIN_ROLE, oldAdmin);

        emit AdminTransferred(oldAdmin, newAdmin);
    }

    /**
     * @notice Get current admin address
     * @return Current single admin address
     */
    function getCurrentAdmin() external view returns (address) {
        return singleAdmin;
    }

    // ---------- ERC721 Receiver implementation ----------

    /// @notice Mark this vault as able to receive ERC721 tokens
    function onERC721Received(address operator, address from, uint256 tokenId, bytes calldata data) external pure returns (bytes4) {
        // Simply accept all incoming NFTs
        operator;
        from;
        tokenId;
        data;
        return IERC721Receiver.onERC721Received.selector;
    }
}
