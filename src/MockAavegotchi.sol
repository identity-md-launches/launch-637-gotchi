// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";

/// @title MockAavegotchi
/// @notice A plain ERC-721 standing in for Aavegotchi NFTs on Sepolia. Not the real Aavegotchi
/// Diamond: no traits, no wearables, no Polygon/Base bridge.
///
/// @dev Admin role: `MINTER` (set once in the constructor) is the only address that can mint. It exists
/// so the operator can create demo inventory for the mock Baazaar; it has no other power (no burn,
/// no pause, no metadata changes). Real Aavegotchi integration is a README TODO.
contract MockAavegotchi is ERC721 {
    /// @notice The only address allowed to mint.
    address public immutable MINTER;

    /// @notice Id the next mint receives; ids start at 1.
    uint256 public nextTokenId = 1;

    error NotMinter();
    error ZeroAddress();
    error ZeroCount();

    modifier onlyMinter() {
        if (msg.sender != MINTER) revert NotMinter();
        _;
    }

    constructor(address minter) ERC721("Mock Aavegotchi", "mGOTCHI") {
        if (minter == address(0)) revert ZeroAddress();
        MINTER = minter;
    }

    /// @notice Mints one gotchi to `to`.
    function mint(address to) external onlyMinter returns (uint256 tokenId) {
        tokenId = nextTokenId++;
        _mint(to, tokenId);
    }

    /// @notice Mints `count` gotchis to `to`; returns the first id (the others follow consecutively).
    function mintBatch(address to, uint256 count) external onlyMinter returns (uint256 firstTokenId) {
        if (count < 1) revert ZeroCount();
        firstTokenId = nextTokenId;
        for (uint256 i = 0; i < count; i++) {
            _mint(to, firstTokenId + i);
        }
        nextTokenId = firstTokenId + count;
    }
}
