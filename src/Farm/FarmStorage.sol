// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../interfaces/IPUSD.sol";
import "../interfaces/IyPUSD.sol";
import "../interfaces/IVault.sol";
import {IFarm} from "../interfaces/IFarm.sol";

abstract contract FarmStorage is IFarm {
    /* ========== Constants ========== */
    uint256 public constant HEALTH_CHECK_TIMEOUT = 3600; // 1 hour timeout for oracle data freshness check

    /* ========== Contract Dependencies ========== */

    IPUSD public pusdToken; // PUSD stablecoin contract
    IyPUSD public ypusdToken; // yPUSD yield token contract
    IVault public vault; // Fund vault contract
    address public _nftManager; // NFT Manager contract address

    /* ========== Permission Roles ========== */

    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE"); // Operations admin role (APY/fees/configuration)

    mapping(address => UserAssetInfo) public userAssets;

    /* ========== Fee Settings ========== */

    uint16 public depositFeeRate = 0; // Deposit fee rate (basis points, 0 = 0%, max 65535)
    uint16 public withdrawFeeRate = 50; // Withdrawal fee rate (basis points, 50 = 0.5%, max 65535)
    uint16 public bridgeFeeRate = 0; // Bridge fee rate (basis points, 50 = 0.5%, max 65535)

    uint256 public minDepositAmount = 10 * 10 ** 6; // Minimum deposit amount (USD, configurable)

    /* ========== Statistics ========== */

    uint256 public totalUsers; // Total number of users
    uint256 public totalVolumeUSD; // Total transaction volume (USD)

    mapping(address => uint256) public assetTotalDeposits; // Total deposits per asset

    /* ========== Staking Mining System ========== */

    uint256 public totalStaked; // Total staked amount
    uint256 public minLockAmount = 100; // Minimum staking amount (PUSD, configurable)

    /* ========== APY History System ========== */

    uint16 public currentAPY; // Current annual percentage yield (basis points, 2000 = 20%, max 65535)

    APYRecord[] public apyHistory; // APY change history
    uint16 public maxAPYHistory = 1000; // Maximum history record count (configurable, max 65535)

    /* ========== Staking Multiplier Configuration System ========== */

    // Multiplier configuration for different lock periods (dynamically adjustable)
    mapping(uint256 => uint16) public lockPeriodMultipliers;

    // Array of supported lock periods
    uint256[] public supportedLockPeriods;

    /* ========== Storage Optimization Configuration ========== */
    uint16 public maxStakesPerUser = 1000; // Maximum stakes per user (configurable, max 65535)

    /* ========== Pool TVL Tracking ========== */
    mapping(uint256 => uint256) public poolTVL; // Total locked value per lock period

    /* ========== Bridge related ========== */ 
    address public bridgeMessenger; // L1StandardBridge or L2StandardBridge address
    mapping(bytes32 => bool) public processedBridgeMessages; // Prevent replay attacks


    // PlaceHolder
    uint256[50] private __gap;
}
