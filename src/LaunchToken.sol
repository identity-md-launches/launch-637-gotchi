// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title LaunchToken ($GOTCHI)
/// @notice The GOTCHI ERC-20: fixed supply, 18 decimals, 1,000,000,000 tokens minted once to the
/// deployer in the constructor. This is the "GotchiToken" module of the brief.
///
/// @dev Deliberately plain: no owner, no mint after construction, no pause, no blocklist, no transfer
/// fee, no upgrade path. The launch factory (or the Sepolia deploy script) receives the whole supply
/// and distributes it; nothing in this project mints, holds or forwards any of it afterwards.
contract LaunchToken is ERC20 {
    /// @notice Total supply in minor units: 10^9 tokens * 10^18.
    uint256 public constant TOTAL_SUPPLY = 1_000_000_000e18;

    constructor() ERC20("GOTCHI", "GOTCHI") {
        _mint(msg.sender, TOTAL_SUPPLY);
    }
}
