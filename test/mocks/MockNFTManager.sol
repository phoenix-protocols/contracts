// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {INFTManager} from "src/interfaces/INFTManager.sol";
import {IFarm} from "src/interfaces/IFarm.sol";

contract MockNFTManager is INFTManager {
    struct LocalStakeRecord {
        bool exists;
        IFarm.StakeRecord data;
    }

    mapping(uint256 => address) public owners;
    mapping(uint256 => bool) public existMap;
    mapping(uint256 => LocalStakeRecord) public records;

    function setOwner(uint256 tokenId, address owner) external {
        owners[tokenId] = owner;
        existMap[tokenId] = true;
    }

    function setStakeRecord(uint256 tokenId, IFarm.StakeRecord memory r) external {
        records[tokenId] = LocalStakeRecord({ exists: true, data: r });
    }

    function exists(uint256 tokenId) external view returns (bool) {
        return existMap[tokenId];
    }

    function ownerOf(uint256 tokenId) external view returns (address) {
        return owners[tokenId];
    }

    function getStakeRecord(uint256 tokenId) external view returns (IFarm.StakeRecord memory) {
        require(records[tokenId].exists, "no record");
        return records[tokenId].data;
    }

    function safeTransferFrom(address from, address to, uint256 tokenId) external {
        require(owners[tokenId] == from, "wrong from");
        owners[tokenId] = to;
    }
}
