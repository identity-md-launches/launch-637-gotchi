// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {SafeCast} from "v4-core/src/libraries/SafeCast.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {SqrtPriceMath} from "v4-core/src/libraries/SqrtPriceMath.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary, toBeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {HookFlags} from "./HookFlags.sol";

/// @title GotchiFeeHook (fee collector)
/// @notice Uniswap v4 hook that skims `FEE_BPS` (0.30%) of the ETH side of every swap in a native-ETH
/// pool and hands it to the FeeSink, straight out of the PoolManager.
///
/// @dev How the ETH fee is charged, whichever way the trade goes:
///  - ETH is the *unspecified* currency (exact-output ETH sale, exact-input ETH purchase): `afterSwap`
///    returns a positive unspecified delta equal to `FEE_BPS` of the ETH the swap actually moved. The
///    trader pays that much more / receives that much less. Exact by construction.
///  - ETH is the *specified* currency (exact-input ETH sale, exact-output ETH purchase): only `beforeSwap`
///    can charge the specified side, before the fill is known. It therefore sizes the fee on the ETH the
///    swap can actually move: `min(|amountSpecified|, ethToLimit)`, where `ethToLimit` is the ETH the pool
///    moves between the spot price and the trader's `sqrtPriceLimitX96` at the current liquidity. A swap
///    that fills completely pays 30 bps of its amount; a swap the price limit cuts short pays 30 bps of
///    what filled, not of what was asked, so an exact-output ETH buyer can never end up paying ETH.
///    `afterSwap` then checks the fee it is about to take against the realised fill and reverts
///    (`FeeOutOfBounds`) if liquidity between spot and limit differed from the spot liquidity by enough
///    to break the 30 bps bound in either direction (more than 30 bps of the gross ETH plus one wei of
///    rounding, or less than 90% of 30 bps of the net ETH, which would otherwise let a trader shape
///    liquidity to shrink their fee). Swaps with the usual MIN/MAX price limits are never affected;
///    price-limited partial fills through third-party positions may need a different limit.
///  In both cases `afterSwap` immediately `take`s the credited ETH to the FeeSink, so the hook never
///  holds a balance and the PoolManager's books net to zero before the unlock ends. The fee sized in
///  `beforeSwap` travels to `afterSwap` in transient storage.
///
/// Permissions enabled: beforeSwap, afterSwap, beforeSwapReturnDelta, afterSwapReturnDelta (address
/// bits 0xCC). Initialization, liquidity and donate callbacks are off: anyone may initialize a pool
/// with this hook, there is no sender or pad gate.
///
/// Wiring: the constructor takes only the PoolManager. The FeeSink binds itself once, from its own
/// constructor, through `bindFeeSink()`; until then no fee is charged. There is no owner, no fee
/// setter, no pause and no way to redirect fees afterwards. Binding is first come, first served, so the
/// hook and the FeeSink must be created in one transaction (`GotchiStackDeployer`, or a launch factory).
contract GotchiFeeHook is IHooks {
    using SafeCast for uint256;
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    /// @notice Swap fee on the ETH side, in basis points.
    uint256 public constant FEE_BPS = 30;
    /// @notice Basis-point denominator.
    uint256 public constant BPS_DENOMINATOR = 10_000;
    /// @notice The permission bits the deployment address must carry (0xCC).
    uint160 public constant HOOK_FLAGS = HookFlags.BEFORE_SWAP | HookFlags.AFTER_SWAP
        | HookFlags.BEFORE_SWAP_RETURN_DELTA | HookFlags.AFTER_SWAP_RETURN_DELTA;
    /// @notice Lower bound, in percent, of the fee an ETH-specified swap must end up paying relative to
    /// 30 bps of its net ETH (guards against liquidity shaped to shrink the pre-sized fee).
    uint256 public constant MIN_REALISED_FEE_PERCENT = 90;

    // Transient slot carrying the specified-side fee from beforeSwap to afterSwap.
    bytes32 private constant PENDING_FEE_SLOT = keccak256("GotchiFeeHook.pendingSpecifiedFee");

    /// @notice The pool manager this hook serves; the only caller allowed to drive its callbacks.
    IPoolManager public immutable POOL_MANAGER;

    /// @notice Where skimmed ETH goes. Zero until the FeeSink binds itself; immutable afterwards.
    address public feeSink;

    /// @notice An ETH fee was skimmed from a swap and sent to the FeeSink.
    event HookFeeTaken(PoolId indexed poolId, address indexed sink, uint256 amountEth);
    /// @notice The FeeSink bound itself to this hook.
    event FeeSinkBound(address indexed sink);

    error NotPoolManager();
    error HookNotImplemented();
    error ZeroAddress();
    error FeeSinkAlreadyBound(address current);
    error FeeOutOfBounds(uint256 fee, uint256 grossEth, uint256 netEth);

    modifier onlyPoolManager() {
        if (msg.sender != address(POOL_MANAGER)) revert NotPoolManager();
        _;
    }

    /// @param poolManager The PoolManager the hook is deployed for (Sepolia:
    /// 0xE03A1074c86CFeDd5C142C4F04F1a1536e203543). The address bits are *not* validated here: a
    /// factory deploys with its own salt. Use `addressHasValidFlags()` after deployment; a hook whose
    /// address does not carry exactly `HOOK_FLAGS` cannot serve a pool and must be redeployed.
    constructor(address poolManager) {
        if (poolManager == address(0)) revert ZeroAddress();
        POOL_MANAGER = IPoolManager(poolManager);
    }

    // ---------------------------------------------------------------------------------------------
    // Wiring
    // ---------------------------------------------------------------------------------------------

    /// @notice Binds the caller as the fee sink, once. Called by the FeeSink's constructor.
    /// @dev First come, first served: create the hook and the FeeSink in the same transaction
    /// (`GotchiStackDeployer.deploy`, or a factory that deploys both). A hook whose binding was taken by
    /// a stranger must be abandoned and redeployed; nothing can rebind it.
    function bindFeeSink() external {
        if (feeSink != address(0)) revert FeeSinkAlreadyBound(feeSink);
        feeSink = msg.sender;
        emit FeeSinkBound(msg.sender);
    }

    // ---------------------------------------------------------------------------------------------
    // Permissions
    // ---------------------------------------------------------------------------------------------

    /// @notice The callbacks this hook implements. Must agree with the bits in its address.
    function getHookPermissions() public pure returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: true,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    /// @notice True when this contract's address carries exactly `HOOK_FLAGS`.
    function addressHasValidFlags() external view returns (bool) {
        return HookFlags.matches(address(this), HOOK_FLAGS);
    }

    // ---------------------------------------------------------------------------------------------
    // Fee math (exposed for the UI and the tests)
    // ---------------------------------------------------------------------------------------------

    /// @notice The fee charged on `ethAmount` of ETH (30 bps, rounded down).
    function feeFor(uint256 ethAmount) public pure returns (uint256) {
        return ethAmount * FEE_BPS / BPS_DENOMINATOR;
    }

    /// @notice True when `params.amountSpecified` refers to currency0 (ETH): exact-input zeroForOne
    /// or exact-output oneForZero.
    function ethIsSpecified(SwapParams calldata params) public pure returns (bool) {
        return (params.amountSpecified < 0) == params.zeroForOne;
    }

    /// @notice True when this hook charges a fee on `key`: a native-ETH pool, with a bound sink.
    function chargesFeeOn(PoolKey calldata key) public view returns (bool) {
        return feeSink != address(0) && key.currency0.isAddressZero();
    }

    /// @notice The ETH the pool would move between its current price and `params.sqrtPriceLimitX96` at
    /// its current liquidity: the most an ETH-specified swap can fill. Returns `type(uint256).max` when
    /// the limit is on the wrong side of the spot price (the pool rejects such a swap anyway).
    function ethToLimit(PoolKey calldata key, SwapParams calldata params) public view returns (uint256) {
        PoolId id = key.toId();
        (uint160 sqrtPriceX96,,,) = POOL_MANAGER.getSlot0(id);
        uint128 liquidity = POOL_MANAGER.getLiquidity(id);
        uint160 limit = params.sqrtPriceLimitX96;
        if (params.zeroForOne) {
            // ETH flows in and the price falls towards the limit.
            if (limit >= sqrtPriceX96 || limit < TickMath.MIN_SQRT_PRICE) return type(uint256).max;
            return SqrtPriceMath.getAmount0Delta(limit, sqrtPriceX96, liquidity, true);
        }
        // ETH flows out and the price rises towards the limit.
        if (limit <= sqrtPriceX96 || limit > TickMath.MAX_SQRT_PRICE) return type(uint256).max;
        return SqrtPriceMath.getAmount0Delta(sqrtPriceX96, limit, liquidity, false);
    }

    /// @notice The fee `beforeSwap` charges an ETH-specified swap: 30 bps of the ETH it can fill.
    function specifiedFeeFor(PoolKey calldata key, SwapParams calldata params) public view returns (uint256) {
        uint256 requested = _abs(params.amountSpecified);
        uint256 fillable = ethToLimit(key, params);
        return feeFor(requested < fillable ? requested : fillable);
    }

    // ---------------------------------------------------------------------------------------------
    // Swap callbacks
    // ---------------------------------------------------------------------------------------------

    /// @inheritdoc IHooks
    function beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        if (!chargesFeeOn(key) || !ethIsSpecified(params)) {
            return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }
        uint256 fee = specifiedFeeFor(key, params);
        _storePendingFee(fee);
        // A positive specified delta: the trader owes the hook `fee` of ETH on top of what the
        // (reduced or enlarged) swap itself moves. Collected and checked in afterSwap.
        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(fee.toInt128(), 0), 0);
    }

    /// @inheritdoc IHooks
    function afterSwap(address, PoolKey calldata key, SwapParams calldata params, BalanceDelta delta, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4, int128)
    {
        if (!chargesFeeOn(key)) return (IHooks.afterSwap.selector, 0);

        uint256 fee = 0;
        int128 hookDeltaUnspecified = 0;
        uint256 ethMoved = _abs(int256(delta.amount0()));
        if (ethIsSpecified(params)) {
            // Charged through the beforeSwap delta; check it against the realised fill, then collect.
            fee = _loadPendingFee();
            _storePendingFee(0);
            _checkRealisedFee(fee, params.amountSpecified < 0, ethMoved);
        } else {
            // ETH is the unspecified side: charge FEE_BPS of the ETH the swap moved.
            fee = feeFor(ethMoved);
            hookDeltaUnspecified = fee.toInt128();
        }
        if (fee > 0) {
            emit HookFeeTaken(key.toId(), feeSink, fee);
            POOL_MANAGER.take(key.currency0, feeSink, fee);
        }
        return (IHooks.afterSwap.selector, hookDeltaUnspecified);
    }

    /// @dev `fee` was sized before the fill. Gross ETH is what the trader moved in total: for an exact
    /// input the pool's intake plus the fee, for an exact output the pool's output (the trader nets the
    /// rest). The fee may not exceed 30 bps of the gross (plus one wei of rounding) and may not fall below
    /// `MIN_REALISED_FEE_PERCENT` of 30 bps of the net.
    function _checkRealisedFee(uint256 fee, bool exactInput, uint256 ethMoved) private pure {
        uint256 gross = exactInput ? ethMoved + fee : ethMoved;
        if (fee > gross) revert FeeOutOfBounds(fee, gross, 0);
        uint256 net = gross - fee;
        if (fee > feeFor(gross) + 1) revert FeeOutOfBounds(fee, gross, net);
        if (fee * 100 < feeFor(net) * MIN_REALISED_FEE_PERCENT) revert FeeOutOfBounds(fee, gross, net);
    }

    function _storePendingFee(uint256 fee) private {
        bytes32 slot = PENDING_FEE_SLOT;
        assembly ("memory-safe") {
            tstore(slot, fee)
        }
    }

    function _loadPendingFee() private view returns (uint256 fee) {
        bytes32 slot = PENDING_FEE_SLOT;
        assembly ("memory-safe") {
            fee := tload(slot)
        }
    }

    function _abs(int256 value) private pure returns (uint256) {
        return value < 0 ? uint256(-value) : uint256(value);
    }

    // ---------------------------------------------------------------------------------------------
    // Callbacks this hook does not enable. Their address bits are off, so the PoolManager never calls
    // them; they exist to satisfy IHooks and refuse everyone.
    // ---------------------------------------------------------------------------------------------

    /// @inheritdoc IHooks
    function beforeInitialize(address, PoolKey calldata, uint160) external pure returns (bytes4) {
        revert HookNotImplemented();
    }

    /// @inheritdoc IHooks
    function afterInitialize(address, PoolKey calldata, uint160, int24) external pure returns (bytes4) {
        revert HookNotImplemented();
    }

    /// @inheritdoc IHooks
    function beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    /// @inheritdoc IHooks
    function afterAddLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    /// @inheritdoc IHooks
    function beforeRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    /// @inheritdoc IHooks
    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    /// @inheritdoc IHooks
    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        revert HookNotImplemented();
    }

    /// @inheritdoc IHooks
    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        revert HookNotImplemented();
    }
}
