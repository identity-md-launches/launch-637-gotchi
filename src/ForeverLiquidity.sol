// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {SqrtPriceMath} from "v4-core/src/libraries/SqrtPriceMath.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {FixedPoint96} from "v4-core/src/libraries/FixedPoint96.sol";

/// @title ForeverLiquidity
/// @notice Owns the ETH/$GOTCHI Uniswap v4 pool's full-range position and never gives it back: there is
/// no function that removes liquidity, collects fees or transfers the position. Anyone may add.
///
/// @dev The pool is "simple": a static LP fee of 0, so the only trading fee is the hook's 0.30% ETH
/// skim, and no LP fee ever accrues to this contract (nothing to collect, no hidden treasury).
/// Initial liquidity is whatever the deployer adds; the amounts are configurable constants of the
/// deploy script, not of this contract.
contract ForeverLiquidity is IUnlockCallback, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    struct CallbackData {
        address depositor;
        uint128 liquidity;
        uint256 ethProvided;
        uint256 tokenProvided;
    }

    /// @notice Static LP fee of the pool (pips). Zero: the hook fee is the whole trading fee.
    uint24 public constant LP_FEE = 0;
    /// @notice Tick spacing of the pool.
    int24 public constant TICK_SPACING = 60;
    /// @notice Lower tick of the single full-range position (largest multiple of 60 above MIN_TICK).
    int24 public constant TICK_LOWER = -887_220;
    /// @notice Upper tick of the single full-range position.
    int24 public constant TICK_UPPER = 887_220;

    /// @notice The Uniswap v4 PoolManager.
    IPoolManager public immutable POOL_MANAGER;
    /// @notice $GOTCHI (currency1; native ETH is currency0).
    IERC20 public immutable TOKEN;
    /// @notice The fee hook attached to the pool.
    IHooks public immutable HOOK;

    /// @notice Total liquidity locked through this contract.
    uint256 public totalLiquidity;

    /// @notice Liquidity was added and locked forever. The amounts paid are returned by `addLiquidity`
    /// and recorded in the PoolManager's own `ModifyLiquidity` event.
    event LiquidityLocked(address indexed depositor, uint128 liquidity);

    error ZeroAddress();
    error NotPoolManager();
    error ZeroLiquidity();
    error PoolNotInitialized();
    error InsufficientEth(uint256 needed, uint256 provided);
    error InsufficientToken(uint256 needed, uint256 provided);
    error UnexpectedDelta();
    error RefundFailed();
    error PriceOutOfRange();

    modifier onlyPoolManager() {
        if (msg.sender != address(POOL_MANAGER)) revert NotPoolManager();
        _;
    }

    constructor(address token, address poolManager, address hook) {
        if (token == address(0) || poolManager == address(0) || hook == address(0)) revert ZeroAddress();
        TOKEN = IERC20(token);
        POOL_MANAGER = IPoolManager(poolManager);
        HOOK = IHooks(hook);
    }

    // ---------------------------------------------------------------------------------------------
    // Pool identity
    // ---------------------------------------------------------------------------------------------

    /// @notice The ETH/$GOTCHI pool key this contract serves.
    function poolKey() public view returns (PoolKey memory) {
        return PoolKey({
            currency0: CurrencyLibrary.ADDRESS_ZERO,
            currency1: Currency.wrap(address(TOKEN)),
            fee: LP_FEE,
            tickSpacing: TICK_SPACING,
            hooks: HOOK
        });
    }

    /// @notice The pool id of `poolKey()`.
    function poolId() public view returns (PoolId) {
        return poolKey().toId();
    }

    /// @notice Initializes the pool at `sqrtPriceX96`. Anyone may call; the PoolManager rejects a
    /// second initialization. The deploy script does this right before adding liquidity.
    function initializePool(uint160 sqrtPriceX96) external nonReentrant returns (int24 tick) {
        tick = POOL_MANAGER.initialize(poolKey(), sqrtPriceX96);
    }

    // ---------------------------------------------------------------------------------------------
    // Adding liquidity
    // ---------------------------------------------------------------------------------------------

    /// @notice Adds `liquidity` to the full-range position, paying with `msg.value` of ETH and up to
    /// `maxTokenAmount` of $GOTCHI pulled from the caller (approve first). Unused ETH and tokens are
    /// returned. The liquidity can never be withdrawn.
    /// @return amountEth ETH actually used.
    /// @return amountToken $GOTCHI actually used.
    function addLiquidity(uint128 liquidity, uint256 maxTokenAmount)
        external
        payable
        nonReentrant
        returns (uint256 amountEth, uint256 amountToken)
    {
        if (liquidity < 1) revert ZeroLiquidity();
        if (maxTokenAmount > 0) TOKEN.safeTransferFrom(msg.sender, address(this), maxTokenAmount);

        bytes memory result = POOL_MANAGER.unlock(
            abi.encode(
                CallbackData({
                    depositor: msg.sender, liquidity: liquidity, ethProvided: msg.value, tokenProvided: maxTokenAmount
                })
            )
        );
        (amountEth, amountToken) = abi.decode(result, (uint256, uint256));

        uint256 tokenRefund = maxTokenAmount - amountToken;
        uint256 ethRefund = msg.value - amountEth;
        if (tokenRefund > 0) TOKEN.safeTransfer(msg.sender, tokenRefund);
        if (ethRefund > 0) {
            (bool ok,) = msg.sender.call{value: ethRefund}("");
            if (!ok) revert RefundFailed();
        }
    }

    /// @inheritdoc IUnlockCallback
    /// @dev Only reachable through `addLiquidity`: the PoolManager calls back whoever called `unlock`.
    function unlockCallback(bytes calldata data) external onlyPoolManager returns (bytes memory) {
        CallbackData memory cb = abi.decode(data, (CallbackData));
        PoolKey memory key = poolKey();

        // Effects and the event first; every call to the PoolManager comes after.
        totalLiquidity += cb.liquidity;
        emit LiquidityLocked(cb.depositor, cb.liquidity);

        (uint256 amountEth, uint256 amountToken) = amountsForLiquidity(cb.liquidity);
        if (amountEth > cb.ethProvided) revert InsufficientEth(amountEth, cb.ethProvided);
        if (amountToken > cb.tokenProvided) revert InsufficientToken(amountToken, cb.tokenProvided);

        (BalanceDelta callerDelta, BalanceDelta feesAccrued) = POOL_MANAGER.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: TICK_LOWER,
                tickUpper: TICK_UPPER,
                liquidityDelta: int256(uint256(cb.liquidity)),
                salt: bytes32(0)
            }),
            ""
        );
        // The pool must owe us nothing and ask exactly what we computed with its own math.
        if (BalanceDelta.unwrap(feesAccrued) != 0) revert UnexpectedDelta();
        if (callerDelta.amount0() != -int256(amountEth) || callerDelta.amount1() != -int256(amountToken)) {
            revert UnexpectedDelta();
        }

        if (amountEth > 0) {
            uint256 paidEth = POOL_MANAGER.settle{value: amountEth}();
            if (paidEth != amountEth) revert UnexpectedDelta();
        }
        if (amountToken > 0) {
            POOL_MANAGER.sync(key.currency1);
            TOKEN.safeTransfer(address(POOL_MANAGER), amountToken);
            uint256 paidToken = POOL_MANAGER.settle();
            if (paidToken != amountToken) revert UnexpectedDelta();
        }
        return abi.encode(amountEth, amountToken);
    }

    // ---------------------------------------------------------------------------------------------
    // Quoting helpers
    // ---------------------------------------------------------------------------------------------

    /// @notice The sqrtPriceX96 at which `tokenAmount` of $GOTCHI is worth `ethAmount` of ETH.
    function sqrtPriceX96ForAmounts(uint256 ethAmount, uint256 tokenAmount) public pure returns (uint160) {
        if (ethAmount < 1 || tokenAmount < 1) revert ZeroLiquidity();
        uint256 ratioX192 = Math.mulDiv(tokenAmount, 1 << 192, ethAmount);
        uint256 sqrtPriceX96 = Math.sqrt(ratioX192);
        if (sqrtPriceX96 > type(uint160).max) revert PriceOutOfRange();
        return uint160(sqrtPriceX96);
    }

    /// @notice The ETH and $GOTCHI the pool will charge for `liquidity` at the current price, computed
    /// with the pool's own rounding.
    function amountsForLiquidity(uint128 liquidity) public view returns (uint256 amountEth, uint256 amountToken) {
        (uint160 sqrtPriceX96, int24 tick,,) = POOL_MANAGER.getSlot0(poolId());
        if (sqrtPriceX96 < 1) revert PoolNotInitialized();
        uint160 sqrtLower = TickMath.getSqrtPriceAtTick(TICK_LOWER);
        uint160 sqrtUpper = TickMath.getSqrtPriceAtTick(TICK_UPPER);
        if (tick < TICK_LOWER) {
            amountEth = SqrtPriceMath.getAmount0Delta(sqrtLower, sqrtUpper, liquidity, true);
        } else if (tick < TICK_UPPER) {
            amountEth = SqrtPriceMath.getAmount0Delta(sqrtPriceX96, sqrtUpper, liquidity, true);
            amountToken = SqrtPriceMath.getAmount1Delta(sqrtLower, sqrtPriceX96, liquidity, true);
        } else {
            amountToken = SqrtPriceMath.getAmount1Delta(sqrtLower, sqrtUpper, liquidity, true);
        }
    }

    /// @notice The largest liquidity that `ethAmount` and `tokenAmount` can fund at the current price,
    /// such that `amountsForLiquidity` of it stays within both budgets.
    function liquidityForAmounts(uint256 ethAmount, uint256 tokenAmount) external view returns (uint128 liquidity) {
        (uint160 sqrtPriceX96,,,) = POOL_MANAGER.getSlot0(poolId());
        if (sqrtPriceX96 < 1) revert PoolNotInitialized();
        uint160 sqrtLower = TickMath.getSqrtPriceAtTick(TICK_LOWER);
        uint160 sqrtUpper = TickMath.getSqrtPriceAtTick(TICK_UPPER);
        if (sqrtPriceX96 <= sqrtLower) {
            liquidity = _liquidityForAmount0(sqrtLower, sqrtUpper, ethAmount);
        } else if (sqrtPriceX96 < sqrtUpper) {
            uint128 liquidity0 = _liquidityForAmount0(sqrtPriceX96, sqrtUpper, ethAmount);
            uint128 liquidity1 = _liquidityForAmount1(sqrtLower, sqrtPriceX96, tokenAmount);
            liquidity = liquidity0 < liquidity1 ? liquidity0 : liquidity1;
        } else {
            liquidity = _liquidityForAmount1(sqrtLower, sqrtUpper, tokenAmount);
        }
        // The pool rounds the amounts it charges up; step down until both budgets hold.
        for (uint256 i = 0; i < 4 && liquidity > 0; i++) {
            (uint256 amountEth, uint256 amountToken) = amountsForLiquidity(liquidity);
            if (amountEth <= ethAmount && amountToken <= tokenAmount) break;
            liquidity -= 1;
        }
    }

    function _liquidityForAmount0(uint160 sqrtA, uint160 sqrtB, uint256 amount0) private pure returns (uint128) {
        uint256 intermediate = FullMath.mulDiv(sqrtA, sqrtB, FixedPoint96.Q96);
        return _toUint128(FullMath.mulDiv(amount0, intermediate, sqrtB - sqrtA));
    }

    function _liquidityForAmount1(uint160 sqrtA, uint160 sqrtB, uint256 amount1) private pure returns (uint128) {
        return _toUint128(FullMath.mulDiv(amount1, FixedPoint96.Q96, sqrtB - sqrtA));
    }

    function _toUint128(uint256 x) private pure returns (uint128) {
        return x > type(uint128).max ? type(uint128).max : uint128(x);
    }

    /// @notice Accepts nothing: ETH only moves through `addLiquidity` and the PoolManager callback.
    receive() external payable {
        revert UnexpectedDelta();
    }
}
