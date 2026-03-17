// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../interfaces/IStakingVault.sol";

/**
 * @title StakingVault
 * @notice Manages staked PUSD principal and reward reserves
 * @dev Separates staking funds from Treasury (Vault) for safety
 *
 * Design Philosophy:
 * - Hold ONLY staking-related PUSD (principal + rewards)
 * - Complete isolation from Treasury/protocol revenue
 * - Only Farm contract can trigger stake deposits/withdrawals
 * - Admin can manage reward reserve for interest payments
 */
contract StakingVault is 
    Initializable,
    AccessControlUpgradeable,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable,
    UUPSUpgradeable,
    IStakingVault
{
    using SafeERC20 for IERC20;

    /* ========== Roles ========== */
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    /* ========== State Variables ========== */
    
    /// @notice PUSD token contract
    address public override pusdToken;
    
    /// @notice Farm contract address (only caller for stake operations)
    address public override farm;
    
    /// @notice Total staked PUSD principal
    uint256 public totalStaked;
    
    /// @notice Reward reserve for interest payments
    uint256 public rewardReserve;

    /* ========== Storage Gap ========== */
    uint256[50] private __gap;

    /* ========== Constructor ========== */

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initialize StakingVault contract
     * @param admin Administrator address
     * @param _pusdToken PUSD token contract address
     * @param _farm Farm contract address
     */
    function initialize(
        address admin,
        address _pusdToken,
        address _farm
    ) public initializer {
        require(admin != address(0), "StakingVault: zero admin");
        require(_pusdToken != address(0), "StakingVault: zero pusd");
        require(_farm != address(0), "StakingVault: zero farm");

        __AccessControl_init();
        __ReentrancyGuard_init();
        __Pausable_init();
        __UUPSUpgradeable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(OPERATOR_ROLE, admin);
        _grantRole(PAUSER_ROLE, admin);

        pusdToken = _pusdToken;
        farm = _farm;
    }

    /* ========== Modifiers ========== */

    modifier onlyFarm() {
        require(msg.sender == farm, "StakingVault: only farm");
        _;
    }

    /* ========== Stake Principal Management ========== */

    /**
     * @notice Deposit PUSD stake from user
     * @dev Only callable by Farm contract
     * @param from User address (must have approved this contract)
     * @param amount Amount to deposit
     */
    function depositStake(address from, uint256 amount) external override nonReentrant whenNotPaused onlyFarm {
        require(amount > 0, "StakingVault: zero amount");
        
        IERC20(pusdToken).safeTransferFrom(from, address(this), amount);
        totalStaked += amount;
        
        emit StakeDeposited(from, amount, totalStaked);
    }

    /**
     * @notice Withdraw staked PUSD to user
     * @dev Only callable by Farm contract
     * @param to Recipient address
     * @param amount Amount to withdraw
     */
    function withdrawStake(address to, uint256 amount) external override nonReentrant whenNotPaused onlyFarm {
        require(to != address(0), "StakingVault: zero recipient");
        require(amount > 0, "StakingVault: zero amount");
        require(totalStaked >= amount, "StakingVault: insufficient staked");
        
        totalStaked -= amount;
        IERC20(pusdToken).safeTransfer(to, amount);
        
        emit StakeWithdrawn(to, amount, totalStaked);
    }

    /* ========== Reward Reserve Management ========== */

    /**
     * @notice Add PUSD to reward reserve
     * @dev Caller must approve this contract first
     * @param amount Amount to add
     */
    function addRewardReserve(uint256 amount) external override nonReentrant onlyRole(OPERATOR_ROLE) {
        require(amount > 0, "StakingVault: zero amount");
        
        IERC20(pusdToken).safeTransferFrom(msg.sender, address(this), amount);
        rewardReserve += amount;
        
        emit RewardReserveAdded(msg.sender, amount, rewardReserve);
    }

    /**
     * @notice Withdraw from reward reserve (emergency)
     * @param to Recipient address
     * @param amount Amount to withdraw
     */
    function withdrawRewardReserve(address to, uint256 amount) external override nonReentrant onlyRole(DEFAULT_ADMIN_ROLE) {
        require(to != address(0), "StakingVault: zero recipient");
        require(amount > 0 && amount <= rewardReserve, "StakingVault: invalid amount");
        
        rewardReserve -= amount;
        IERC20(pusdToken).safeTransfer(to, amount);
        
        emit RewardReserveWithdrawn(to, amount, rewardReserve);
    }

    /**
     * @notice Distribute reward to user (for unstake)
     * @dev Only callable by Farm contract
     * @param to Recipient address
     * @param amount Reward amount
     * @return success Whether distribution succeeded
     */
    function distributeReward(address to, uint256 amount) external override nonReentrant whenNotPaused onlyFarm returns (bool success) {
        if (amount == 0) return true;
        
        if (rewardReserve >= amount) {
            rewardReserve -= amount;
            IERC20(pusdToken).safeTransfer(to, amount);
            emit RewardDistributed(to, amount, rewardReserve);
            return true;
        } else {
            emit InsufficientRewardReserve(amount, rewardReserve);
            return false;
        }
    }

    /**
     * @notice Compound reward into stake (for renewal)
     * @dev Only callable by Farm contract. 
     *      Moves amount from rewardReserve to totalStaked (no actual transfer needed)
     * @param amount Reward amount to compound
     * @return success Whether compound succeeded
     */
    function compoundReward(uint256 amount) external override nonReentrant whenNotPaused onlyFarm returns (bool success) {
        if (amount == 0) return true;
        
        if (rewardReserve >= amount) {
            rewardReserve -= amount;
            totalStaked += amount;
            emit RewardCompounded(amount, rewardReserve);
            return true;
        } else {
            emit InsufficientRewardReserve(amount, rewardReserve);
            return false;
        }
    }

    /* ========== View Functions ========== */

    /**
     * @notice Get total staked PUSD amount
     * @return Total staked amount
     */
    function getTotalStaked() external view override returns (uint256) {
        return totalStaked;
    }

    /**
     * @notice Get current reward reserve balance
     * @return Reward reserve amount
     */
    function getRewardReserve() external view override returns (uint256) {
        return rewardReserve;
    }

    /* ========== Admin Functions ========== */

    /**
     * @notice Update Farm contract address
     * @param newFarm New Farm contract address
     */
    function setFarm(address newFarm) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(newFarm != address(0), "StakingVault: zero farm");
        address oldFarm = farm;
        farm = newFarm;
        emit FarmUpdated(oldFarm, newFarm);
    }

    /**
     * @notice Pause contract
     */
    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    /**
     * @notice Unpause contract
     */
    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    /* ========== Emergency Functions ========== */

    /**
     * @notice Emergency withdraw all PUSD (admin only, when paused)
     * @param to Recipient address
     */
    function emergencyWithdraw(address to) external onlyRole(DEFAULT_ADMIN_ROLE) whenPaused {
        require(to != address(0), "StakingVault: zero recipient");
        uint256 balance = IERC20(pusdToken).balanceOf(address(this));
        if (balance > 0) {
            IERC20(pusdToken).safeTransfer(to, balance);
        }
        totalStaked = 0;
        rewardReserve = 0;
    }

    /* ========== UUPS Upgrade ========== */

    function _authorizeUpgrade(address newImplementation) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}
}
