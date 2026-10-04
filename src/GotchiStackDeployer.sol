// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {GotchiFeeHook} from "./GotchiFeeHook.sol";
import {FeeSink} from "./FeeSink.sol";
import {ForeverLiquidity} from "./ForeverLiquidity.sol";

/// @title GotchiStackDeployer
/// @notice One-shot helper that creates, in a single transaction, everything whose wiring is first come,
/// first served: the hook (CREATE2 at a mined address), the FeeSink that binds itself to it, the
/// ForeverLiquidity contract for that hook, the pool initialization at the chosen price, and the initial
/// forever liquidity at exactly that price.
///
/// @dev Doing all of it in one transaction closes the windows a mempool watcher could otherwise use between
/// the deploy script's transactions: calling `bindFeeSink()` on the fresh hook to become the permanent fee
/// recipient, initializing the fixed pool key at an arbitrary price, and moving the price of the freshly
/// initialized, still empty pool (a swap against a pool with no liquidity moves `sqrtPriceX96` to the
/// caller's limit for free) so that an exact-band deposit sent in a later transaction reverts. The hook's
/// own constructor still takes only the PoolManager address.
///
/// Admin role: `DEPLOYER` (the account that created this helper) is the only caller of `deploy`, so a
/// stranger cannot consume a mined salt first. The helper holds nothing between calls, owns nothing
/// afterwards and has no power over the contracts it created. A launch factory that deploys the hook and
/// the FeeSink in one transaction does not need it.
contract GotchiStackDeployer {
    using SafeERC20 for IERC20;

    /// @notice The Uniswap v4 PoolManager every hook created here is bound to.
    address public immutable POOL_MANAGER;
    /// @notice The only account allowed to call `deploy`.
    address public immutable DEPLOYER;

    // The ForeverLiquidity contract currently allowed to refund ETH to this helper (only during `deploy`).
    address private _refunder;

    /// @notice A hook, sink and forever-liquidity trio was created, the pool initialized at `tick` and
    /// `liquidity` locked at `sqrtPriceX96` (0 when no initial liquidity was requested).
    event StackDeployed(
        address indexed hook,
        address indexed sink,
        address indexed forever,
        bytes32 salt,
        uint160 sqrtPriceX96,
        int24 tick,
        uint128 liquidity
    );

    error ZeroAddress();
    error NotDeployer();
    error HookAddressLacksFlags(address hook);
    error SinkNotBound(address hook, address sink);
    error ZeroInitialLiquidity();
    error UnexpectedEth();
    error RefundFailed();

    constructor(address poolManager) {
        if (poolManager == address(0)) revert ZeroAddress();
        POOL_MANAGER = poolManager;
        DEPLOYER = msg.sender;
    }

    /// @notice Creates the hook at `CREATE2(this, salt)`, the FeeSink bound to it, the ForeverLiquidity
    /// contract for `token` and that hook, initializes the ETH/token pool at `sqrtPriceX96` and, when
    /// `msg.value` or `initialTokens` is non-zero, locks the largest full-range position those amounts fund
    /// at exactly that price. Unused ETH and tokens are returned to the caller.
    /// @param salt A salt such that the hook address carries exactly `GotchiFeeHook.HOOK_FLAGS`
    /// (`HookMiner.find(address(this), 0xCC, creationCode, 0)`).
    /// @param initialTokens GOTCHI pulled from the caller for the initial liquidity (approve this helper
    /// first); `msg.value` is the ETH side.
    function deploy(
        bytes32 salt,
        address token,
        address baazaar,
        address escrow,
        uint160 sqrtPriceX96,
        uint256 initialTokens
    ) external payable returns (GotchiFeeHook hook, FeeSink sink, ForeverLiquidity forever, uint128 liquidity) {
        if (msg.sender != DEPLOYER) revert NotDeployer();
        hook = new GotchiFeeHook{salt: salt}(POOL_MANAGER);
        if (!hook.addressHasValidFlags()) revert HookAddressLacksFlags(address(hook));
        sink = new FeeSink(address(hook), baazaar, escrow);
        if (hook.feeSink() != address(sink)) revert SinkNotBound(address(hook), address(sink));
        forever = new ForeverLiquidity(token, POOL_MANAGER, address(hook));
        int24 tick = forever.initializePool(sqrtPriceX96);

        if (msg.value > 0 || initialTokens > 0) {
            liquidity = forever.liquidityForAmounts(msg.value, initialTokens);
            if (liquidity < 1) revert ZeroInitialLiquidity();
            if (initialTokens > 0) {
                IERC20(token).safeTransferFrom(msg.sender, address(this), initialTokens);
                IERC20(token).forceApprove(address(forever), initialTokens);
            }
            _refunder = address(forever);
            forever.addLiquidityWithin{value: msg.value}(liquidity, initialTokens, sqrtPriceX96, sqrtPriceX96);
            _refunder = address(0);
            // Rounding dust comes back from ForeverLiquidity to this helper; pass it on to the caller.
            uint256 tokenDust = IERC20(token).balanceOf(address(this));
            if (tokenDust > 0) IERC20(token).safeTransfer(msg.sender, tokenDust);
            uint256 ethDust = address(this).balance;
            if (ethDust > 0) {
                (bool ok,) = msg.sender.call{value: ethDust}("");
                if (!ok) revert RefundFailed();
            }
        }
        emit StackDeployed(address(hook), address(sink), address(forever), salt, sqrtPriceX96, tick, liquidity);
    }

    /// @notice Accepts only the ETH refund of the ForeverLiquidity contract being funded inside `deploy`.
    receive() external payable {
        if (msg.sender != _refunder) revert UnexpectedEth();
    }
}
