// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../interfaces/IPUSD.sol";
import "../interfaces/IyPUSD.sol";
import "../interfaces/IVault.sol";
import "../interfaces/IStakingVault.sol";
import {IFarm} from "../interfaces/IFarm.sol";

abstract contract FarmStorage is IFarm {
    /* ========== Contract Dependencies ========== */

    IPUSD public pusdToken; // PUSD stablecoin contract
    IyPUSD public ypusdToken; // yPUSD yield token contract
    IVault public vault; // Treasury vault contract (underlying assets + protocol revenue)
    address public _nftManager; // NFT Manager contract address

    /* ========== Permission Roles ========== */

    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE"); // Operations admin role (APY/fees/configuration)
    bytes32 public constant BRIDGE_ROLE = keccak256("BRIDGE_ROLE"); // Bridge management role

    mapping(address => UserAssetInfo) public userAssets;

    /* ========== Fee Settings ========== */

    uint16 public depositFeeRate = 0; // Deposit fee rate (basis points, 0 = 0%, max 65535)
    uint16 public withdrawFeeRate = 50; // Withdrawal fee rate (basis points, 50 = 0.5%, max 65535)
    uint16 public bridgeFeeRate = 0; // Bridge fee rate (basis points, 50 = 0.5%, max 65535)

    // Custom fee rates: feeType => user => customRate (0 = use default)
    // feeType: 0=deposit, 1=withdraw, 2=bridge
    mapping(uint8 => mapping(address => uint16)) public customFeeRates;

    uint256 public minDepositAmount = 0; // Minimum deposit amount (PUSD wei, set via config)

    /* ========== Statistics ========== */

    uint256 public totalUsers; // Total number of users
    uint256 public totalVolumeUSD; // Total transaction volume (USD)

    mapping(address => uint256) public assetTotalDeposits; // Total deposits per asset

    /* ========== Staking Mining System ========== */

    uint256 public totalStaked; // Total staked amount
    uint256 public minLockAmount = 0; // Minimum staking amount (PUSD wei, set via config)

    /* ========== APY History System ========== */

    uint16 public currentAPY; // Current annual percentage yield (basis points, 2000 = 20%, max 65535)

    APYRecord[] public apyHistory; // APY change history
    uint16 public maxAPYHistory = 1000; // Maximum history record count (configurable, max 65535)

    /* ========== Storage Optimization Configuration ========== */
    uint16 public maxStakesPerUser = 1000; // Maximum stakes per user (configurable, max 65535)

    /* ========== Pool Management ========== */
    uint256 public nextPoolId = 1; // Next pool ID (starts from 1, 0 is invalid)
    mapping(uint256 => Pool) public pools; // poolId => Pool
    mapping(bytes32 => bool) public poolNameExists; // keccak256(name) => exists (uniqueness check)

    /* ========== Bridge related ========== */
    address public bridgeMessenger;
    mapping(uint256 => bool) public isSupportedBridgeChain; // Supported bridge destination chains

    /* ========== New Variables (append only, do not insert!) ========== */
    IStakingVault public stakingVault; // Staking vault contract (staked principal + reward reserve)

    // PlaceHolder
    uint256[49] private __gap;
}
