// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {TestERC20} from "v4-core/src/test/TestERC20.sol";

import {GotchiFixture} from "./utils/GotchiFixture.sol";
import {GotchiFeeHook} from "../src/GotchiFeeHook.sol";
import {HookFlags} from "../src/HookFlags.sol";
import {FeeSink} from "../src/FeeSink.sol";

contract GotchiFeeHookTest is GotchiFixture {
    using PoolIdLibrary for PoolKey;

    uint256 constant BPS = 10_000;

    // ---------------------------------------------------------------------------------------------
    // Deployment, flags and wiring
    // ---------------------------------------------------------------------------------------------

    function test_flagConstantsMatchV4Core() public pure {
        assertEq(HookFlags.BEFORE_INITIALIZE, Hooks.BEFORE_INITIALIZE_FLAG);
        assertEq(HookFlags.AFTER_INITIALIZE, Hooks.AFTER_INITIALIZE_FLAG);
        assertEq(HookFlags.BEFORE_ADD_LIQUIDITY, Hooks.BEFORE_ADD_LIQUIDITY_FLAG);
        assertEq(HookFlags.AFTER_ADD_LIQUIDITY, Hooks.AFTER_ADD_LIQUIDITY_FLAG);
        assertEq(HookFlags.BEFORE_REMOVE_LIQUIDITY, Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG);
        assertEq(HookFlags.AFTER_REMOVE_LIQUIDITY, Hooks.AFTER_REMOVE_LIQUIDITY_FLAG);
        assertEq(HookFlags.BEFORE_SWAP, Hooks.BEFORE_SWAP_FLAG);
        assertEq(HookFlags.AFTER_SWAP, Hooks.AFTER_SWAP_FLAG);
        assertEq(HookFlags.BEFORE_DONATE, Hooks.BEFORE_DONATE_FLAG);
        assertEq(HookFlags.AFTER_DONATE, Hooks.AFTER_DONATE_FLAG);
        assertEq(HookFlags.BEFORE_SWAP_RETURN_DELTA, Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG);
        assertEq(HookFlags.AFTER_SWAP_RETURN_DELTA, Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG);
        assertEq(HookFlags.AFTER_ADD_LIQUIDITY_RETURN_DELTA, Hooks.AFTER_ADD_LIQUIDITY_RETURNS_DELTA_FLAG);
        assertEq(HookFlags.AFTER_REMOVE_LIQUIDITY_RETURN_DELTA, Hooks.AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG);
        assertEq(HookFlags.ALL, Hooks.ALL_HOOK_MASK);
    }

    function test_permissionsMatchAddressAndConstant() public view {
        Hooks.Permissions memory p = hook.getHookPermissions();
        assertTrue(p.beforeSwap && p.afterSwap && p.beforeSwapReturnDelta && p.afterSwapReturnDelta);
        assertFalse(
            p.beforeInitialize || p.afterInitialize || p.beforeAddLiquidity || p.afterAddLiquidity
                || p.beforeRemoveLiquidity || p.afterRemoveLiquidity || p.beforeDonate || p.afterDonate
                || p.afterAddLiquidityReturnDelta || p.afterRemoveLiquidityReturnDelta
        );
        assertEq(hook.HOOK_FLAGS(), 0xCC);
        assertEq(
            hook.HOOK_FLAGS(),
            Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
                | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
        );
        assertEq(HookFlags.flagsOf(address(hook)), hook.HOOK_FLAGS());
        assertTrue(hook.addressHasValidFlags());
        // v4-core's own validation agrees with the address.
        Hooks.validateHookPermissions(IHooks(address(hook)), p);
        assertTrue(Hooks.isValidHookAddress(IHooks(address(hook)), 0));
    }

    function test_constructorOnlyTakesThePoolManager() public view {
        assertEq(address(hook.POOL_MANAGER()), address(manager));
        assertEq(hook.FEE_BPS(), 30);
        assertEq(hook.BPS_DENOMINATOR(), BPS);
    }

    function test_feeSinkBoundOnceByTheSinkConstructor() public {
        assertEq(hook.feeSink(), address(sink));
        vm.expectRevert(abi.encodeWithSelector(GotchiFeeHook.FeeSinkAlreadyBound.selector, address(sink)));
        hook.bindFeeSink();
        // A second FeeSink cannot steal the binding either.
        vm.expectRevert(abi.encodeWithSelector(GotchiFeeHook.FeeSinkAlreadyBound.selector, address(sink)));
        new FeeSink(address(hook), address(baazaar), address(escrow));
    }

    function test_unminedAddressDeploysButReportsInvalidFlags() public {
        GotchiFeeHook plain = new GotchiFeeHook(address(manager));
        assertFalse(plain.addressHasValidFlags());
        assertEq(address(plain.POOL_MANAGER()), address(manager));
    }

    function testFuzz_feeForIsThirtyBps(uint256 amount) public view {
        amount = bound(amount, 0, type(uint128).max);
        assertEq(hook.feeFor(amount), amount * 30 / BPS);
    }

    function test_ethIsSpecifiedTruthTable() public view {
        assertTrue(hook.ethIsSpecified(SwapParams(true, -1, 0)));
        assertFalse(hook.ethIsSpecified(SwapParams(true, 1, 0)));
        assertFalse(hook.ethIsSpecified(SwapParams(false, -1, 0)));
        assertTrue(hook.ethIsSpecified(SwapParams(false, 1, 0)));
    }

    // ---------------------------------------------------------------------------------------------
    // Fee flow: every swap direction skims 30 bps of ETH into the sink
    // ---------------------------------------------------------------------------------------------

    function test_exactInputEthForToken_skimsThirtyBpsOfTheInput() public {
        int256 amount = -1 ether;
        uint256 fee = 0.003 ether;
        uint256 sinkBefore = address(sink).balance;

        vm.expectEmit(true, true, false, true, address(hook));
        emit GotchiFeeHook.HookFeeTaken(key.toId(), address(sink), fee);
        vm.expectEmit(true, false, false, true, address(sink));
        emit FeeSink.FeesCollected(address(manager), fee);
        BalanceDelta hooked = swap(key, true, amount);
        BalanceDelta plain = swap(plainKey, true, amount + int256(fee));

        assertEq(hooked.amount0(), amount, "trader pays exactly the specified ETH");
        assertEq(hooked.amount1(), plain.amount1(), "output equals a plain swap of the input minus the fee");
        assertEq(address(sink).balance - sinkBefore, fee, "sink received the fee");
        assertEq(sink.totalCollected(), fee);
        _assertHookHoldsNothing();
    }

    function test_exactOutputEthForToken_skimsThirtyBpsOfTheEthPaid() public {
        int256 amount = 1_000_000e18;
        BalanceDelta plain = swap(plainKey, true, amount);
        uint256 ethPaidPlain = uint256(-int256(plain.amount0()));
        uint256 fee = hook.feeFor(ethPaidPlain);
        assertGt(fee, 0);

        BalanceDelta hooked = swap(key, true, amount);
        assertEq(hooked.amount1(), amount, "trader receives exactly the specified tokens");
        assertEq(uint256(-int256(hooked.amount0())), ethPaidPlain + fee, "trader pays the plain cost plus the fee");
        assertEq(address(sink).balance, fee);
        _assertHookHoldsNothing();
    }

    function test_exactInputTokenForEth_skimsThirtyBpsOfTheEthReceived() public {
        int256 amount = -1_000_000e18;
        BalanceDelta plain = swap(plainKey, false, amount);
        uint256 ethOutPlain = uint256(int256(plain.amount0()));
        uint256 fee = hook.feeFor(ethOutPlain);
        assertGt(fee, 0);

        BalanceDelta hooked = swap(key, false, amount);
        assertEq(hooked.amount1(), amount, "trader pays exactly the specified tokens");
        assertEq(uint256(int256(hooked.amount0())), ethOutPlain - fee, "trader receives the plain output minus the fee");
        assertEq(address(sink).balance, fee);
        _assertHookHoldsNothing();
    }

    function test_exactOutputTokenForEth_skimsThirtyBpsOfTheOutput() public {
        int256 amount = 1 ether;
        uint256 fee = 0.003 ether;
        BalanceDelta hooked = swap(key, false, amount);
        BalanceDelta plain = swap(plainKey, false, amount + int256(fee));

        assertEq(hooked.amount0(), amount, "trader receives exactly the specified ETH");
        assertEq(hooked.amount1(), plain.amount1(), "trader pays what a plain swap for output plus fee costs");
        assertEq(address(sink).balance, fee);
        _assertHookHoldsNothing();
    }

    function test_feesAccumulateAcrossSwaps() public {
        swap(key, true, -1 ether);
        swap(key, true, -2 ether);
        swap(key, false, 0.5 ether);
        assertEq(address(sink).balance, 0.003 ether + 0.006 ether + 0.0015 ether);
        assertEq(sink.totalCollected(), address(sink).balance);
        _assertHookHoldsNothing();
    }

    function test_tinySwapRoundsFeeDownToZeroWithoutReverting() public {
        BalanceDelta hooked = swap(key, true, -300);
        assertEq(hooked.amount0(), -300);
        assertEq(address(sink).balance, 0);
    }

    function test_noFeeUntilASinkIsBound() public {
        GotchiFeeHook unbound = deployHook(address(manager), uint256(lastHookSalt) + 1);
        assertEq(unbound.feeSink(), address(0));
        PoolKey memory unboundKey = PoolKey({
            currency0: CurrencyLibrary.ADDRESS_ZERO,
            currency1: Currency.wrap(address(token)),
            fee: 0,
            tickSpacing: 60,
            hooks: IHooks(address(unbound))
        });
        manager.initialize(unboundKey, forever.sqrtPriceX96ForAmounts(INITIAL_ETH, INITIAL_TOKENS));
        lpRouter.modifyLiquidity{value: INITIAL_ETH}(
            unboundKey,
            ModifyLiquidityParams(forever.TICK_LOWER(), forever.TICK_UPPER(), int256(uint256(seededLiquidity)), 0),
            ""
        );
        BalanceDelta unhooked = swap(unboundKey, true, -1 ether);
        BalanceDelta plain = swap(plainKey, true, -1 ether);
        assertEq(unhooked.amount1(), plain.amount1(), "no fee while unbound");
        assertEq(address(sink).balance, 0);
    }

    function test_noFeeOnPoolsWithoutNativeEth() public {
        TestERC20 a = new TestERC20(1e30);
        TestERC20 b = new TestERC20(1e30);
        (TestERC20 t0, TestERC20 t1) = address(a) < address(b) ? (a, b) : (b, a);
        t0.approve(address(lpRouter), type(uint256).max);
        t1.approve(address(lpRouter), type(uint256).max);
        t0.approve(address(swapRouter), type(uint256).max);
        t1.approve(address(swapRouter), type(uint256).max);
        PoolKey memory erc20Key = PoolKey({
            currency0: Currency.wrap(address(t0)),
            currency1: Currency.wrap(address(t1)),
            fee: 0,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        manager.initialize(erc20Key, 79228162514264337593543950336);
        lpRouter.modifyLiquidity(erc20Key, ModifyLiquidityParams(-887220, 887220, 1_000e18, 0), "");

        uint256 sinkBefore = address(sink).balance;
        BalanceDelta delta = swapRouter.swap(
            erc20Key, SwapParams(true, -1e18, TickMath.MIN_SQRT_PRICE + 1), PoolSwapTestSettings.none(), ""
        );
        assertEq(delta.amount0(), -1e18);
        assertEq(address(sink).balance, sinkBefore, "no ETH fee on a token/token pool");
        _assertHookHoldsNothing();
    }

    // ---------------------------------------------------------------------------------------------
    // Access control
    // ---------------------------------------------------------------------------------------------

    function test_swapCallbacksRefuseNonManager() public {
        SwapParams memory params = SwapParams(true, -1 ether, TickMath.MIN_SQRT_PRICE + 1);
        vm.expectRevert(GotchiFeeHook.NotPoolManager.selector);
        hook.beforeSwap(address(this), key, params, "");
        vm.expectRevert(GotchiFeeHook.NotPoolManager.selector);
        hook.afterSwap(address(this), key, params, BalanceDelta.wrap(0), "");
        vm.prank(address(0xBAD));
        vm.expectRevert(GotchiFeeHook.NotPoolManager.selector);
        hook.afterSwap(address(this), key, params, BalanceDelta.wrap(0), "");
    }

    function test_disabledCallbacksRevertEvenForTheManager() public {
        vm.startPrank(address(manager));
        ModifyLiquidityParams memory lp = ModifyLiquidityParams(-60, 60, 1, bytes32(0));
        BalanceDelta zero = BalanceDelta.wrap(0);

        vm.expectRevert(GotchiFeeHook.HookNotImplemented.selector);
        hook.beforeInitialize(address(this), key, 1);
        vm.expectRevert(GotchiFeeHook.HookNotImplemented.selector);
        hook.afterInitialize(address(this), key, 1, 0);
        vm.expectRevert(GotchiFeeHook.HookNotImplemented.selector);
        hook.beforeAddLiquidity(address(this), key, lp, "");
        vm.expectRevert(GotchiFeeHook.HookNotImplemented.selector);
        hook.afterAddLiquidity(address(this), key, lp, zero, zero, "");
        vm.expectRevert(GotchiFeeHook.HookNotImplemented.selector);
        hook.beforeRemoveLiquidity(address(this), key, lp, "");
        vm.expectRevert(GotchiFeeHook.HookNotImplemented.selector);
        hook.afterRemoveLiquidity(address(this), key, lp, zero, zero, "");
        vm.expectRevert(GotchiFeeHook.HookNotImplemented.selector);
        hook.beforeDonate(address(this), key, 1, 1, "");
        vm.expectRevert(GotchiFeeHook.HookNotImplemented.selector);
        hook.afterDonate(address(this), key, 1, 1, "");
        vm.stopPrank();
    }

    function _assertHookHoldsNothing() internal view {
        assertEq(address(hook).balance, 0, "hook keeps no ETH");
        assertEq(token.balanceOf(address(hook)), 0, "hook keeps no tokens");
    }
}

/// @dev Small helper so the token/token swap reads like the others.
library PoolSwapTestSettings {
    function none() internal pure returns (PoolSwapTestSettingsStruct.TestSettings memory) {
        return PoolSwapTestSettingsStruct.TestSettings({takeClaims: false, settleUsingBurn: false});
    }
}

import {PoolSwapTest as PoolSwapTestSettingsStruct} from "v4-core/src/test/PoolSwapTest.sol";
