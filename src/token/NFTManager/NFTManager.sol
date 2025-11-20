// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/token/ERC721/extensions/ERC721BurnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "../../interfaces/IFarm.sol";
import {NFTManagerStorage} from "./NFTManagerStorage.sol";

/**
 * @title NFTManager
 * @notice Each NFT represents a single staking record. Metadata is stored on-chain and can be edited by authorized accounts.
 */
contract NFTManager is Initializable, ERC721BurnableUpgradeable, AccessControlUpgradeable, UUPSUpgradeable, OwnableUpgradeable, NFTManagerStorage {
    // ---------- Modifiers ----------
    modifier onlyEditor() {
        require(hasRole(METADATA_EDITOR_ROLE, _msgSender()) || _msgSender() == owner(), "NFTManager: not authorized to edit metadata");
        _;
    }

    modifier onlyMinter() {
        require(hasRole(MINTER_ROLE, _msgSender()) || _msgSender() == owner(), "NFTManager: not authorized to mint");
        _;
    }

    modifier onlyAdmin() {
        require(hasRole(DEFAULT_ADMIN_ROLE, _msgSender()) || _msgSender() == owner(), "NFTManager: not admin");
        _;
    }

    modifier onlyFarm() {
        require(_msgSender() == farm, "NFTManager: only farm can call");
        _;
    }

    // ---------- Initializer ----------
    /// @notice Used instead of constructor when deploying behind UUPS proxy
    function initialize(string memory name_, string memory symbol_, address admin, address farm_) public initializer {
        __ERC721_init(name_, symbol_);
        __AccessControl_init();
        __UUPSUpgradeable_init();
        __Ownable_init(admin);

        farm = farm_;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(MINTER_ROLE, farm);
        _grantRole(METADATA_EDITOR_ROLE, farm);
    }

    // ---------- Core: Mint Stake NFT ----------
    /**
     * @notice Mint a new NFT representing a staking record.
     * @dev Stores a IFarm.StakeRecord in on-chain metadata.
     */
    function mintStakeNFT(address to, uint256 amount, uint64 lockPeriod, uint16 rewardMultiplier, uint256 pendingReward) external onlyMinter returns (uint256) {
        uint256 tokenId = _nextTokenId();

        _safeMint(to, tokenId);

        uint64 currentTime = uint64(block.timestamp);

        _stakeRecords[tokenId] = IFarm.StakeRecord({amount: amount, startTime: currentTime, lockPeriod: lockPeriod, lastClaimTime: currentTime, rewardMultiplier: rewardMultiplier, active: true, pendingReward: pendingReward});

        emit StakeNFTMinted(tokenId, to, amount, currentTime, lockPeriod, rewardMultiplier, pendingReward);

        return tokenId;
    }

    // ---------- Metadata Editing ----------
    /**
     * @notice Edit full staking metadata of a token.
     * @dev Only metadata editors or owner/approved addresses can call this.
     */
    function updateStakeRecord(uint256 tokenId, uint256 amount, uint64 lastClaimTime, uint16 rewardMultiplier, bool active, uint256 pendingReward) external onlyEditor {
        _requireOwned(tokenId);

        IFarm.StakeRecord storage r = _stakeRecords[tokenId];

        r.amount = amount;
        r.lastClaimTime = lastClaimTime;
        r.rewardMultiplier = rewardMultiplier;
        r.active = active;
        r.pendingReward = pendingReward;

        emit StakeRecordUpdated(tokenId, amount, lastClaimTime, rewardMultiplier, active, pendingReward);
    }

    /**
     * @notice Update reward-related metadata only.
     */
    function updateRewardInfo(uint256 tokenId, uint256 pendingReward, uint64 lastClaimTime) external onlyEditor {
        _requireOwned(tokenId);

        IFarm.StakeRecord storage r = _stakeRecords[tokenId];
        r.pendingReward = pendingReward;
        r.lastClaimTime = lastClaimTime;
        emit StakeRecordUpdated(tokenId, r.amount, r.lastClaimTime, r.rewardMultiplier, r.active, r.pendingReward);
    }

    function updateStakeRecord(uint256 tokenId, IFarm.StakeRecord calldata newRecord) external onlyFarm {
        _requireOwned(tokenId);
        _stakeRecords[tokenId] = newRecord;
    }

    // ---------- Views ----------
    function getStakeRecord(uint256 tokenId) external view returns (IFarm.StakeRecord memory) {
        _requireOwned(tokenId);
        return _stakeRecords[tokenId];
    }

    // ---------- TokenURI Management ----------
    function setBaseURI(string memory newBaseURI) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _baseTokenURI = newBaseURI;
        emit BaseURIUpdated(newBaseURI);
    }

    function _baseURI() internal view override returns (string memory) {
        return _baseTokenURI;
    }

    function setTokenURI(uint256 tokenId, string memory newTokenURI) external onlyEditor {
        _requireOwned(tokenId);
        _setTokenURI(tokenId, newTokenURI);
    }

    function _setTokenURI(uint256 tokenId, string memory newTokenURI) internal {
        _tokenURIs[tokenId] = newTokenURI;
    }

    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        _requireOwned(tokenId);

        string memory uri = _tokenURIs[tokenId];
        string memory base = _baseURI();

        if (bytes(base).length > 0) {
            if (bytes(uri).length > 0) {
                return string(abi.encodePacked(base, uri));
            } else {
                return string(abi.encodePacked(base, _toString(tokenId)));
            }
        }

        return uri;
    }

    // ---------- exists  ----------
    function exists(uint256 tokenId) public view returns (bool) {
        return _ownerOf(tokenId) != address(0);
    }

    // ---------- Burn ----------
    function burn(uint256 tokenId) public override onlyEditor {
        super.burn(tokenId);

        delete _stakeRecords[tokenId];
        if (bytes(_tokenURIs[tokenId]).length != 0) {
            delete _tokenURIs[tokenId];
        }
    }

    // ---------- Utility: uint256 -> string ----------
    function _toString(uint256 value) internal pure returns (string memory) {
        if (value == 0) return "0";
        uint256 temp = value;
        uint256 digits;
        while (temp != 0) {
            digits++;
            temp /= 10;
        }
        bytes memory buffer = new bytes(digits);
        while (value != 0) {
            digits -= 1;
            buffer[digits] = bytes1(uint8(48 + (value % 10)));
            value /= 10;
        }
        return string(buffer);
    }

    // ---------- Token ID Tracker ----------
    function _nextTokenId() internal returns (uint256) {
        _tokenIdTracker += 1;
        return _tokenIdTracker;
    }

    // ---------- UUPS Upgrade Permission ----------
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}

    // ---------- Multiple Inheritance ----------
    function supportsInterface(bytes4 interfaceId) public view override(ERC721Upgradeable, AccessControlUpgradeable) returns (bool) {
        return super.supportsInterface(interfaceId);
    }

    // Reserved storage gap
    uint256[50] private __gap;
}
