// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {yPUSDStorage} from "./yPUSDStorage.sol";

/**
 * @title yPUSD - Yield-bearing PUSD Vault
 * @notice ERC-4626 tokenized vault for PUSD with linear yield release
 * @dev Users deposit PUSD to receive yPUSD shares. 
 *      Yield is injected via accrueYield() and released linearly over time.
 *      
 * Key features:
 * - ERC-4626 compliant: deposit/withdraw/redeem
 * - Linear yield release: prevents flash loan attacks
 * - Cap limit: maximum total supply of shares
 * - Pausable: admin can pause deposits/withdrawals
 * - Upgradeable: UUPS pattern
 *
 * Anti-Flash Loan Design:
 *   When yield is injected, it's released linearly over the specified duration.
 *   This prevents attackers from depositing right before yield injection
 *   and withdrawing immediately after to capture disproportionate yield.
 */
contract yPUSD is 
    Initializable, 
    ERC4626Upgradeable, 
    AccessControlUpgradeable, 
    PausableUpgradeable, 
    UUPSUpgradeable, 
    yPUSDStorage 
{
    using SafeERC20 for IERC20;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initialize the yPUSD vault
     * @param _pusd The underlying PUSD token address
     * @param _cap Maximum total supply of yPUSD shares
     * @param admin Administrator address
     */
    function initialize(IERC20 _pusd, uint256 _cap, address admin) public initializer {
        __ERC4626_init(_pusd);
        __ERC20_init("Yield Phoenix USD Token", "yPUSD");
        __AccessControl_init();
        __Pausable_init();
        __UUPSUpgradeable_init();

        cap = _cap;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    /* ========== ERC-4626 Overrides ========== */

    /**
     * @dev Override decimals to return 6 (matching PUSD)
     */
    function decimals() public view virtual override(ERC4626Upgradeable) returns (uint8) {
        return 6;
    }

    /**
     * @dev Override decimalsOffset to add 1000 virtual shares for inflation attack protection
     *      This makes donation attacks unprofitable by ensuring attackers lose ~50%+ of donated funds
     *      to the virtual shares. With offset=3, virtual shares = 10^3 = 1000.
     */
    function _decimalsOffset() internal view virtual override returns (uint8) {
        return 3;
    }

    /**
     * @dev Override maxDeposit to enforce cap
     */
    function maxDeposit(address) public view virtual override returns (uint256) {
        if (paused()) return 0;
        uint256 currentSupply = totalSupply();
        if (currentSupply >= cap) return 0;
        // Convert remaining share capacity to assets
        return _convertToAssets(cap - currentSupply, Math.Rounding.Floor);
    }

    /**
     * @dev Override maxMint to enforce cap
     */
    function maxMint(address) public view virtual override returns (uint256) {
        if (paused()) return 0;
        uint256 currentSupply = totalSupply();
        if (currentSupply >= cap) return 0;
        return cap - currentSupply;
    }

    /**
     * @dev Override maxWithdraw to respect pause
     */
    function maxWithdraw(address owner) public view virtual override returns (uint256) {
        if (paused()) return 0;
        return super.maxWithdraw(owner);
    }

    /**
     * @dev Override maxRedeem to respect pause
     */
    function maxRedeem(address owner) public view virtual override returns (uint256) {
        if (paused()) return 0;
        return super.maxRedeem(owner);
    }

    /**
     * @dev Override _deposit to add pause check and cap enforcement
     */
    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal virtual override whenNotPaused {
        require(totalSupply() + shares <= cap, "yPUSD: cap exceeded");
        super._deposit(caller, receiver, assets, shares);
    }

    /**
     * @dev Override _withdraw to add pause check
     */
    function _withdraw(
        address caller,
        address receiver,
        address owner,
        uint256 assets,
        uint256 shares
    ) internal virtual override whenNotPaused {
        super._withdraw(caller, receiver, owner, assets, shares);
    }

    /* ========== Total Assets Override ========== */

    /**
     * @notice Returns the total assets available to shareholders
     * @dev Only counts released yield, not unvested yield
     * @return Total assets including base deposits + released yield
     */
    function totalAssets() public view virtual override returns (uint256) {
        // Start with actual PUSD balance
        uint256 actualBalance = IERC20(asset()).balanceOf(address(this));
        
        // Subtract unvested yield
        uint256 unvested = _getUnvestedYield();
        
        // Protection against underflow (shouldn't happen in normal operation)
        if (unvested >= actualBalance) {
            return 0;
        }
        
        return actualBalance - unvested;
    }

    /**
     * @notice Get the amount of yield that hasn't been released yet
     * @dev Uses time-based proportion to avoid precision loss from rate calculation
     * @return Amount of unvested yield
     */
    function _getUnvestedYield() internal view returns (uint256) {
        // No active vesting or vesting completed
        if (vestingEndTime == 0 || block.timestamp >= vestingEndTime) {
            return 0;
        }
        
        // Calculate remaining time as proportion of total vesting period
        // unvestedYield stores the total yield for current vesting period
        // We calculate: unvested = totalYield * remainingTime / totalTime
        uint256 remainingTime = vestingEndTime - block.timestamp;
        uint256 totalTime = vestingEndTime - lastVestingUpdate;
        
        // Prevent division by zero (shouldn't happen in normal operation)
        if (totalTime == 0) {
            return 0;
        }
        
        // Use proportion to avoid precision loss
        return (unvestedYield * remainingTime) / totalTime;
    }

    /* ========== Yield Injection ========== */

    /**
     * @notice Inject yield into the vault with linear release
     * @dev Only callable by YIELD_INJECTOR_ROLE
     *      Yield is released linearly over the specified duration to prevent flash loan attacks.
     *      If called while previous yield is still vesting, remaining unvested yield is added
     *      to the new yield and a new vesting schedule is created.
     *      
     *      Precision: Uses time-proportion calculation instead of rate-based to avoid
     *      precision loss from integer division. The unvestedYield stores the total
     *      yield amount, and actual unvested is calculated as:
     *      unvested = unvestedYield * remainingTime / totalTime
     *
     * @param amount Amount of PUSD to inject as yield
     * @param duration Duration over which yield will be released (in seconds)
     */
    function accrueYield(uint256 amount, uint256 duration) external onlyRole(YIELD_INJECTOR_ROLE) {
        require(amount > 0, "yPUSD: zero amount");
        require(duration >= MIN_VESTING_DURATION, "yPUSD: duration too short");
        require(duration <= MAX_VESTING_DURATION, "yPUSD: duration too long");
        
        // Transfer PUSD from caller
        IERC20 pusd = IERC20(asset());
        pusd.safeTransferFrom(msg.sender, address(this), amount);
        
        // Calculate currently unvested yield from previous vesting
        uint256 currentUnvested = _getUnvestedYield();
        
        // Update released yield tracking (settle previous vesting)
        if (currentUnvested < unvestedYield) {
            uint256 newlyReleased = unvestedYield - currentUnvested;
            releasedYield += newlyReleased;
            emit VestingUpdated(newlyReleased, releasedYield);
        }
        
        // New total unvested = remaining unvested from previous + new amount
        uint256 totalUnvested = currentUnvested + amount;
        
        // Set new vesting schedule
        // vestingRate is kept for informational purposes (view function)
        vestingRate = totalUnvested / duration;
        vestingEndTime = block.timestamp + duration;
        lastVestingUpdate = block.timestamp;
        unvestedYield = totalUnvested;  // This is the total yield for this vesting period
        
        emit YieldAccrued(amount, duration, vestingRate);
    }

    /**
     * @notice Settle vesting state (useful before querying accurate state)
     * @dev Anyone can call this to update the released yield accounting
     */
    function settleVesting() external {
        _settleVesting();
    }

    /**
     * @notice Internal function to settle vesting
     * @dev Updates storage to reflect current vesting state
     */
    function _settleVesting() internal {
        uint256 currentUnvested = _getUnvestedYield();
        
        if (currentUnvested < unvestedYield) {
            uint256 newlyReleased = unvestedYield - currentUnvested;
            releasedYield += newlyReleased;
            
            // Update storage to current state
            unvestedYield = currentUnvested;
            lastVestingUpdate = block.timestamp;
            
            emit VestingUpdated(newlyReleased, releasedYield);
        }
    }

    /* ========== View Functions ========== */

    /**
     * @notice Get current vesting information
     * @return _vestingEndTime When vesting ends
     * @return _vestingRate Rate of yield release per second
     * @return _unvestedYield Amount of yield not yet released
     * @return _releasedYield Total yield released so far
     */
    function getVestingInfo() external view returns (
        uint256 _vestingEndTime,
        uint256 _vestingRate,
        uint256 _unvestedYield,
        uint256 _releasedYield
    ) {
        return (
            vestingEndTime,
            vestingRate,
            _getUnvestedYield(),  // Calculate current unvested
            releasedYield + (unvestedYield - _getUnvestedYield())  // Include pending releases
        );
    }

    /**
     * @notice Get the current exchange rate (assets per share)
     * @return Exchange rate scaled by 1e18
     */
    function exchangeRate() external view returns (uint256) {
        uint256 supply = totalSupply();
        if (supply == 0) return 1e18;
        return (totalAssets() * 1e18) / supply;
    }

    /**
     * @notice Get the underlying PUSD value of a user's yPUSD holdings
     * @param user The user address
     * @return The PUSD value
     */
    function underlyingBalanceOf(address user) external view returns (uint256) {
        return convertToAssets(balanceOf(user));
    }

    /* ========== Admin Functions ========== */

    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    /**
     * @notice Update the cap
     * @param newCap New maximum total supply
     */
    function setCap(uint256 newCap) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(newCap >= totalSupply(), "yPUSD: cap below current supply");
        cap = newCap;
    }

    /* ========== UUPS Upgrade ========== */

    function _authorizeUpgrade(address newImplementation) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}
}
