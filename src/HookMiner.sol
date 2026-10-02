// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HookFlags} from "./HookFlags.sol";

/// @title HookMiner
/// @notice Finds a CREATE2 salt that places a hook at an address carrying exactly the wanted bits.
/// @dev Pure and loop-bounded; used by the deployment script and the tests. The expected number of
/// attempts is 2^14 (one in 16,384 addresses matches), well inside `MAX_LOOP`.
library HookMiner {
    uint256 internal constant MAX_LOOP = 300_000;

    error NoSaltFound(uint160 flags);

    /// @param deployer The address that will execute CREATE2 (the CREATE2 factory for scripts, the
    /// test contract for tests).
    /// @param flags The permission bits the address must carry, exactly.
    /// @param creationCode The hook's creation code with constructor arguments already appended.
    /// @param start The first salt to try (lets a caller skip salts that are already taken).
    /// @return hookAddress The address CREATE2 will produce.
    /// @return salt The salt to use.
    function find(address deployer, uint160 flags, bytes memory creationCode, uint256 start)
        internal
        pure
        returns (address hookAddress, bytes32 salt)
    {
        bytes32 initCodeHash = keccak256(creationCode);
        for (uint256 i = start; i < start + MAX_LOOP; i++) {
            salt = bytes32(i);
            hookAddress = computeAddress(deployer, salt, initCodeHash);
            if (HookFlags.matches(hookAddress, flags)) return (hookAddress, salt);
        }
        revert NoSaltFound(flags);
    }

    /// @notice The CREATE2 address for `deployer`, `salt` and `initCodeHash`.
    function computeAddress(address deployer, bytes32 salt, bytes32 initCodeHash) internal pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), deployer, salt, initCodeHash)))));
    }
}
