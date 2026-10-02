// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {GotchiFeeHook} from "./GotchiFeeHook.sol";
import {FeeSink} from "./FeeSink.sol";
import {ForeverLiquidity} from "./ForeverLiquidity.sol";

/// @title GotchiStackDeployer
/// @notice One-shot helper that creates, in a single transaction, everything whose wiring is first come,
/// first served: the hook (CREATE2 at a mined address), the FeeSink that binds itself to it, the
/// ForeverLiquidity contract for that hook, and the pool initialization at the chosen price.
///
/// @dev Doing these four steps in one transaction closes the two windows a mempool watcher could
/// otherwise use between the deploy script's transactions: calling `bindFeeSink()` on the fresh hook to
/// become the permanent fee recipient, and initializing the fixed pool key at an arbitrary price. The
/// hook's own constructor still takes only the PoolManager address.
///
/// Admin role: `DEPLOYER` (the account that created this helper) is the only caller of `deploy`, so a
/// stranger cannot consume a mined salt first. The helper holds nothing, owns nothing afterwards and has
/// no power over the contracts it created. A launch factory that deploys the hook and the FeeSink in one
/// transaction does not need it.
contract GotchiStackDeployer {
    /// @notice The Uniswap v4 PoolManager every hook created here is bound to.
    address public immutable POOL_MANAGER;
    /// @notice The only account allowed to call `deploy`.
    address public immutable DEPLOYER;

    /// @notice A hook, sink and forever-liquidity trio was created and the pool initialized at `tick`.
    event StackDeployed(
        address indexed hook,
        address indexed sink,
        address indexed forever,
        bytes32 salt,
        uint160 sqrtPriceX96,
        int24 tick
    );

    error ZeroAddress();
    error NotDeployer();
    error HookAddressLacksFlags(address hook);
    error SinkNotBound(address hook, address sink);

    constructor(address poolManager) {
        if (poolManager == address(0)) revert ZeroAddress();
        POOL_MANAGER = poolManager;
        DEPLOYER = msg.sender;
    }

    /// @notice Creates the hook at `CREATE2(this, salt)`, the FeeSink bound to it, the ForeverLiquidity
    /// contract for `token` and that hook, and initializes the ETH/token pool at `sqrtPriceX96`.
    /// @param salt A salt such that the hook address carries exactly `GotchiFeeHook.HOOK_FLAGS`
    /// (`HookMiner.find(address(this), 0xCC, creationCode, 0)`).
    function deploy(bytes32 salt, address token, address baazaar, address escrow, uint160 sqrtPriceX96)
        external
        returns (GotchiFeeHook hook, FeeSink sink, ForeverLiquidity forever)
    {
        if (msg.sender != DEPLOYER) revert NotDeployer();
        hook = new GotchiFeeHook{salt: salt}(POOL_MANAGER);
        if (!hook.addressHasValidFlags()) revert HookAddressLacksFlags(address(hook));
        sink = new FeeSink(address(hook), baazaar, escrow);
        if (hook.feeSink() != address(sink)) revert SinkNotBound(address(hook), address(sink));
        forever = new ForeverLiquidity(token, POOL_MANAGER, address(hook));
        int24 tick = forever.initializePool(sqrtPriceX96);
        emit StackDeployed(address(hook), address(sink), address(forever), salt, sqrtPriceX96, tick);
    }
}
