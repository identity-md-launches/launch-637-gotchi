// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";

import {GotchiFixture} from "../utils/GotchiFixture.sol";
import {LaunchToken} from "../../src/LaunchToken.sol";
import {GotchiFeeHook} from "../../src/GotchiFeeHook.sol";
import {FeeSink} from "../../src/FeeSink.sol";
import {ForeverLiquidity} from "../../src/ForeverLiquidity.sol";

/// @notice Swaps in all four directions (and with price limits that truncate exact-input fills) on the
/// hooked ETH/GOTCHI pool and mirrors each one on an identical pool without the hook. The un-hooked pool
/// is the oracle: the hooked trade must equal the plain trade plus a 30 bps ETH fee, and both pools must
/// stay in lockstep. Ghost sums track the fees and the PoolManager's ETH so that nothing the hook is
/// credited can stay behind in the manager.
contract HookSwapHandler is Test {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    uint256 internal constant BPS = 10_000;
    uint256 internal constant FEE_BPS = 30;

    PoolManager public manager;
    LaunchToken public token;
    GotchiFeeHook public hook;
    FeeSink public sink;
    ForeverLiquidity public forever;
    PoolSwapTest public swapRouter;
    PoolModifyLiquidityTest public lpRouter;
    PoolKey public key;
    PoolKey public plainKey;

    uint256 public ghostFees;
    int256 public ghostManagerEthDelta;
    uint256 public ghostSwaps;
    uint256 public ghostPartialFills;
    uint256 public ghostLiquidityAdds;
    string[] public violations;

    receive() external payable {}

    constructor(
        PoolManager manager_,
        LaunchToken token_,
        GotchiFeeHook hook_,
        FeeSink sink_,
        ForeverLiquidity forever_,
        PoolSwapTest swapRouter_,
        PoolModifyLiquidityTest lpRouter_,
        PoolKey memory key_,
        PoolKey memory plainKey_
    ) {
        manager = manager_;
        token = token_;
        hook = hook_;
        sink = sink_;
        forever = forever_;
        swapRouter = swapRouter_;
        lpRouter = lpRouter_;
        key = key_;
        plainKey = plainKey_;
        token.approve(address(swapRouter), type(uint256).max);
        token.approve(address(lpRouter), type(uint256).max);
        token.approve(address(forever), type(uint256).max);
    }

    function violationCount() external view returns (uint256) {
        return violations.length;
    }

    // ---------------------------------------------------------------------------------------------
    // Swaps
    // ---------------------------------------------------------------------------------------------

    /// @dev ETH in, exact input. The hooked pool swaps `amount - fee` internally, so the plain pool is
    /// asked for exactly that. A tight limit (when `limitBps > 0`) truncates both fills identically.
    function swapExactInEth(uint256 amount, uint256 limitBps) external {
        amount = bound(amount, 1e9, 2 ether);
        uint256 fee = amount * FEE_BPS / BPS;
        uint160 limit = _lowerLimit(bound(limitBps, 0, 300));
        uint256 sinkBefore = address(sink).balance;
        int256 managerBefore = int256(address(manager).balance);

        BalanceDelta p = _swap(plainKey, true, -int256(amount - fee), limit, amount);
        BalanceDelta h = _swap(key, true, -int256(amount), limit, amount);

        _check(h.amount1() == p.amount1(), "exact-in ETH: token output differs from plain pool at amount - fee");
        _check(h.amount0() == p.amount0() - int256(fee), "exact-in ETH: trader pays plain cost plus the fee");
        _check(address(sink).balance == sinkBefore + fee, "exact-in ETH: sink did not get 30 bps of the input");
        if (uint256(-int256(p.amount0())) < amount - fee) ghostPartialFills += 1;
        _account(fee, managerBefore);
    }

    /// @dev ETH out, exact output. The hooked pool buys `amount + fee` and keeps the fee.
    function swapExactOutEth(uint256 amount) external {
        amount = bound(amount, 1e9, 1 ether);
        uint256 fee = amount * FEE_BPS / BPS;
        uint256 sinkBefore = address(sink).balance;
        int256 managerBefore = int256(address(manager).balance);

        BalanceDelta p = _swap(plainKey, false, int256(amount + fee), TickMath.MAX_SQRT_PRICE - 1, 0);
        BalanceDelta h = _swap(key, false, int256(amount), TickMath.MAX_SQRT_PRICE - 1, 0);

        _check(h.amount0() == int256(amount), "exact-out ETH: trader did not receive the specified ETH");
        _check(h.amount1() == p.amount1(), "exact-out ETH: token cost differs from plain pool at amount + fee");
        _check(address(sink).balance == sinkBefore + fee, "exact-out ETH: sink did not get 30 bps of the output");
        _account(fee, managerBefore);
    }

    /// @dev Tokens in, exact input: the fee is 30 bps of the ETH the pool pays out.
    function swapExactInToken(uint256 amount, uint256 limitBps) external {
        amount = bound(amount, 1e12, 5_000_000e18);
        uint160 limit = _upperLimit(bound(limitBps, 0, 300));
        uint256 sinkBefore = address(sink).balance;
        int256 managerBefore = int256(address(manager).balance);

        BalanceDelta p = _swap(plainKey, false, -int256(amount), limit, 0);
        BalanceDelta h = _swap(key, false, -int256(amount), limit, 0);

        uint256 fee = uint256(int256(p.amount0())) * FEE_BPS / BPS;
        _check(h.amount1() == p.amount1(), "exact-in token: token input differs from plain pool");
        _check(h.amount0() == p.amount0() - int256(fee), "exact-in token: trader receives plain output minus fee");
        _check(address(sink).balance == sinkBefore + fee, "exact-in token: sink did not get 30 bps of the ETH out");
        if (uint256(-int256(p.amount1())) < amount) ghostPartialFills += 1;
        _account(fee, managerBefore);
    }

    /// @dev Tokens out, exact output: the fee is 30 bps of the ETH the pool charges.
    function swapExactOutToken(uint256 amount) external {
        amount = bound(amount, 1e12, 2_000_000e18);
        uint256 sinkBefore = address(sink).balance;
        int256 managerBefore = int256(address(manager).balance);

        BalanceDelta p = _swap(plainKey, true, int256(amount), TickMath.MIN_SQRT_PRICE + 1, 100 ether);
        BalanceDelta h = _swap(key, true, int256(amount), TickMath.MIN_SQRT_PRICE + 1, 100 ether);

        uint256 fee = uint256(-int256(p.amount0())) * FEE_BPS / BPS;
        _check(h.amount1() == int256(amount), "exact-out token: trader did not receive the specified tokens");
        _check(h.amount0() == p.amount0() - int256(fee), "exact-out token: trader pays plain cost plus fee");
        _check(address(sink).balance == sinkBefore + fee, "exact-out token: sink did not get 30 bps of the ETH in");
        _account(fee, managerBefore);
    }

    // ---------------------------------------------------------------------------------------------
    // Liquidity
    // ---------------------------------------------------------------------------------------------

    /// @dev Adds the same liquidity to both pools so they stay comparable.
    function addLiquidity(uint256 liquidity) external {
        liquidity = bound(liquidity, 1e12, uint256(forever.totalLiquidity()) / 4);
        (uint256 eth, uint256 tok) = forever.amountsForLiquidity(uint128(liquidity));
        if (eth > 50 ether || tok > token.balanceOf(address(this)) / 4) return;
        int256 managerBefore = int256(address(manager).balance);
        uint256 totalBefore = forever.totalLiquidity();

        (uint256 usedEth, uint256 usedTok) = forever.addLiquidity{value: eth}(uint128(liquidity), tok);
        lpRouter.modifyLiquidity{value: eth}(
            plainKey,
            ModifyLiquidityParams({
                tickLower: forever.TICK_LOWER(),
                tickUpper: forever.TICK_UPPER(),
                liquidityDelta: int256(liquidity),
                salt: bytes32(0)
            }),
            ""
        );

        _check(usedEth == eth && usedTok == tok, "addLiquidity used other amounts than quoted");
        _check(forever.totalLiquidity() == totalBefore + liquidity, "totalLiquidity did not grow");
        _check(address(forever).balance == 0 && token.balanceOf(address(forever)) == 0, "forever kept funds");
        ghostManagerEthDelta += int256(address(manager).balance) - managerBefore;
        ghostLiquidityAdds += 1;
    }

    // ---------------------------------------------------------------------------------------------
    // Internals
    // ---------------------------------------------------------------------------------------------

    function _swap(PoolKey memory k, bool zeroForOne, int256 amountSpecified, uint160 limit, uint256 value)
        private
        returns (BalanceDelta)
    {
        return swapRouter.swap{value: value}(
            k,
            SwapParams({zeroForOne: zeroForOne, amountSpecified: amountSpecified, sqrtPriceLimitX96: limit}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    function _lowerLimit(uint256 bps) private view returns (uint160) {
        if (bps == 0) return TickMath.MIN_SQRT_PRICE + 1;
        (uint160 price,,,) = IPoolManager(address(manager)).getSlot0(plainKey.toId());
        return price - uint160(uint256(price) * bps / BPS);
    }

    function _upperLimit(uint256 bps) private view returns (uint160) {
        if (bps == 0) return TickMath.MAX_SQRT_PRICE - 1;
        (uint160 price,,,) = IPoolManager(address(manager)).getSlot0(plainKey.toId());
        return price + uint160(uint256(price) * bps / BPS);
    }

    /// @dev The manager must end each pair of swaps holding exactly the trader-side ETH: the fee the hook
    /// is credited must have left towards the sink in the same transaction.
    function _account(uint256 fee, int256 managerBefore) private {
        ghostFees += fee;
        ghostSwaps += 1;
        ghostManagerEthDelta += int256(address(manager).balance) - managerBefore;
        _check(address(hook).balance == 0 && token.balanceOf(address(hook)) == 0, "hook holds funds after a swap");
    }

    function _check(bool condition, string memory what) private {
        if (!condition) violations.push(what);
    }
}

/// forge-config: default.invariant.runs = 32
/// forge-config: default.invariant.depth = 40
contract HookSwapInvariantTest is StdInvariant, GotchiFixture {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    HookSwapHandler handler;
    uint256 managerEthAtStart;

    function setUp() public override {
        super.setUp();
        handler = new HookSwapHandler(manager, token, hook, sink, forever, swapRouter, lpRouter, key, plainKey);
        vm.deal(address(handler), 1_000_000 ether);
        token.transfer(address(handler), 500_000_000e18);
        managerEthAtStart = address(manager).balance;

        targetContract(address(handler));
    }

    function invariant_sinkHoldsExactlyTheFees() public view {
        assertEq(address(sink).balance, handler.ghostFees(), "sink balance is the sum of 30 bps fees");
        assertEq(sink.totalCollected(), handler.ghostFees(), "totalCollected agrees");
        assertEq(sink.totalSpent(), 0, "nothing bought in this suite");
    }

    function invariant_hookNeverHoldsValue() public view {
        assertEq(address(hook).balance, 0, "hook keeps no ETH");
        assertEq(token.balanceOf(address(hook)), 0, "hook keeps no tokens");
    }

    function invariant_managerEthMatchesTraderFlowsMinusFees() public view {
        assertEq(
            int256(address(manager).balance),
            int256(managerEthAtStart) + handler.ghostManagerEthDelta(),
            "the manager's ETH changed by something other than the trades and the fees taken"
        );
    }

    function invariant_hookedPoolTracksThePlainPool() public view {
        IPoolManager pm = IPoolManager(address(manager));
        (uint160 hookedPrice, int24 hookedTick,,) = pm.getSlot0(key.toId());
        (uint160 plainPrice, int24 plainTick,,) = pm.getSlot0(plainKey.toId());
        assertEq(hookedPrice, plainPrice, "price diverged from the fee-less pool");
        assertEq(hookedTick, plainTick, "tick diverged from the fee-less pool");
        assertEq(pm.getLiquidity(key.toId()), pm.getLiquidity(plainKey.toId()), "liquidity diverged");
    }

    function invariant_noLpFeesAccrue() public view {
        (uint256 global0, uint256 global1) = IPoolManager(address(manager)).getFeeGrowthGlobals(key.toId());
        assertEq(global0, 0, "LP fee is zero: no ETH fee growth");
        assertEq(global1, 0, "LP fee is zero: no token fee growth");
    }

    function invariant_noViolations() public {
        uint256 n = handler.violationCount();
        if (n > 0) emit log_named_string("first violation", handler.violations(0));
        assertEq(n, 0, "a handler expectation failed; see the logged violation");
    }

    function afterInvariant() public {
        emit log_named_uint("swaps", handler.ghostSwaps());
        emit log_named_uint("partial fills", handler.ghostPartialFills());
        emit log_named_uint("liquidity adds", handler.ghostLiquidityAdds());
        emit log_named_uint("fees (wei)", handler.ghostFees());
    }
}
