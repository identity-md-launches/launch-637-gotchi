// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {TestERC20} from "v4-core/src/test/TestERC20.sol";

import {GotchiFixture} from "../utils/GotchiFixture.sol";
import {GotchiFeeHook} from "../../src/GotchiFeeHook.sol";
import {FeeSink} from "../../src/FeeSink.sol";

/// @notice Hook edges: other pools, binding races, rounding, and the callbacks called directly.
/// forge-config: default.fuzz.runs = 256
contract HookEdgeTest is GotchiFixture {
    using BeforeSwapDeltaLibrary for BeforeSwapDelta;

    function test_feeIsChargedOnAnyNativeEthPoolThatUsesTheHook() public {
        TestERC20 other = new TestERC20(1e30);
        other.approve(address(lpRouter), type(uint256).max);
        other.approve(address(swapRouter), type(uint256).max);
        PoolKey memory otherKey = PoolKey({
            currency0: CurrencyLibrary.ADDRESS_ZERO,
            currency1: Currency.wrap(address(other)),
            fee: 0,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        manager.initialize(otherKey, 79228162514264337593543950336);
        lpRouter.modifyLiquidity{value: 100 ether}(
            otherKey, ModifyLiquidityParams(-887_220, 887_220, 100e18, bytes32(0)), ""
        );
        assertTrue(hook.chargesFeeOn(otherKey));
        BalanceDelta delta = swap(otherKey, true, -1 ether);
        assertEq(delta.amount0(), -1 ether);
        assertEq(address(sink).balance, 0.003 ether, "the sink collects from every ETH pool on this hook");
    }

    function test_aBindingClaimedBeforeTheSinkDeploysMakesTheSinkDeploymentRevert() public {
        GotchiFeeHook fresh = deployHook(address(manager), uint256(lastHookSalt) + 1);
        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        fresh.bindFeeSink();
        assertEq(fresh.feeSink(), stranger);
        // The sink's constructor binds, so a sink can never silently deploy against a hook that already
        // points elsewhere; the deploy script's `feeSink()` check relies on this.
        vm.expectRevert(abi.encodeWithSelector(GotchiFeeHook.FeeSinkAlreadyBound.selector, stranger));
        new FeeSink(address(fresh), address(baazaar), address(escrow));
    }

    function testFuzz_exactInputEthFeeMatchesThePlainPool(uint256 amount) public {
        amount = bound(amount, 1e6, 5 ether);
        uint256 fee = amount * 30 / 10_000;
        BalanceDelta hooked = swap(key, true, -int256(amount));
        BalanceDelta plain = swap(plainKey, true, -int256(amount - fee));
        assertEq(hooked.amount0(), -int256(amount), "trader pays exactly the input");
        assertEq(hooked.amount1(), plain.amount1(), "output equals the plain swap of input minus fee");
        assertEq(address(sink).balance, fee, "sink gets 30 bps of the input");
        assertEq(address(hook).balance, 0);
    }

    function testFuzz_exactInputTokenFeeIsThirtyBpsOfTheEthOut(uint256 amount) public {
        amount = bound(amount, 1e12, 10_000_000e18);
        BalanceDelta plain = swap(plainKey, false, -int256(amount));
        uint256 ethOut = uint256(int256(plain.amount0()));
        uint256 fee = ethOut * 30 / 10_000;
        BalanceDelta hooked = swap(key, false, -int256(amount));
        assertEq(hooked.amount1(), -int256(amount));
        assertEq(uint256(int256(hooked.amount0())), ethOut - fee, "trader receives the plain output minus the fee");
        assertEq(address(sink).balance, fee);
    }

    function testFuzz_exactOutputEthAlwaysDeliversTheSpecifiedAmountWhenTheFillIsComplete(uint256 amount) public {
        amount = bound(amount, 1e9, 2 ether);
        uint256 fee = amount * 30 / 10_000;
        BalanceDelta plain = swap(plainKey, false, int256(amount + fee));
        BalanceDelta hooked = swap(key, false, int256(amount));
        assertEq(hooked.amount0(), int256(amount), "trader receives exactly the specified ETH");
        assertEq(hooked.amount1(), plain.amount1(), "trader pays for amount plus fee");
        assertEq(address(sink).balance, fee);
    }

    function test_feeRoundsDownAtTheThirtyBpsBoundary() public {
        swap(key, true, -333);
        assertEq(address(sink).balance, 0, "333 wei * 30 / 10000 rounds to zero");
        swap(key, true, -334);
        assertEq(address(sink).balance, 1, "334 wei * 30 / 10000 rounds to one wei");
        swap(key, true, -666);
        assertEq(address(sink).balance, 2, "666 wei: one more wei");
        swap(key, true, -667);
        assertEq(address(sink).balance, 4, "667 wei: two wei");
    }

    function test_beforeSwapQuotesTheFeeOnlyWhenEthIsSpecified() public {
        vm.startPrank(address(manager));
        (bytes4 selector, BeforeSwapDelta delta, uint24 lpFee) =
            hook.beforeSwap(address(this), key, SwapParams(true, -1 ether, TickMath.MIN_SQRT_PRICE + 1), "");
        assertEq(selector, IHooks.beforeSwap.selector);
        assertEq(delta.getSpecifiedDelta(), 0.003 ether, "fee on the specified ETH");
        assertEq(delta.getUnspecifiedDelta(), 0);
        assertEq(lpFee, 0, "no LP fee override");

        (, delta,) = hook.beforeSwap(address(this), key, SwapParams(false, 1 ether, TickMath.MAX_SQRT_PRICE - 1), "");
        assertEq(delta.getSpecifiedDelta(), 0.003 ether, "exact-output ETH is also specified");

        (, delta,) = hook.beforeSwap(address(this), key, SwapParams(true, 1e18, TickMath.MIN_SQRT_PRICE + 1), "");
        assertEq(BeforeSwapDelta.unwrap(delta), 0, "token specified: nothing charged before the swap");
        (, delta,) = hook.beforeSwap(address(this), key, SwapParams(false, -1e18, TickMath.MAX_SQRT_PRICE - 1), "");
        assertEq(BeforeSwapDelta.unwrap(delta), 0, "token specified: nothing charged before the swap");

        PoolKey memory tokenOnly = key;
        tokenOnly.currency0 = Currency.wrap(address(0x1234));
        (, delta,) = hook.beforeSwap(address(this), tokenOnly, SwapParams(true, -1 ether, 0), "");
        assertEq(BeforeSwapDelta.unwrap(delta), 0, "no ETH in the pool: nothing charged");
        vm.stopPrank();
    }

    function test_afterSwapWithNoEthMovementTakesNothing() public {
        uint256 sinkBefore = address(sink).balance;
        vm.prank(address(manager));
        (bytes4 selector, int128 unspecified) =
            hook.afterSwap(address(this), key, SwapParams(false, -1e18, 0), BalanceDelta.wrap(0), "");
        assertEq(selector, IHooks.afterSwap.selector);
        assertEq(unspecified, 0);
        assertEq(address(sink).balance, sinkBefore);
    }

    function test_afterSwapOnATokenOnlyPoolReturnsZero() public {
        PoolKey memory tokenOnly = key;
        tokenOnly.currency0 = Currency.wrap(address(0x1234));
        vm.prank(address(manager));
        (, int128 unspecified) =
            hook.afterSwap(address(this), tokenOnly, SwapParams(false, -1e18, 0), BalanceDelta.wrap(0), "");
        assertEq(unspecified, 0);
        assertFalse(hook.chargesFeeOn(tokenOnly));
    }

    function test_hookHasNoWayToRedirectOrPauseFees() public {
        string[6] memory signatures = [
            "setFeeSink(address)",
            "setFee(uint256)",
            "pause()",
            "transferOwnership(address)",
            "withdraw()",
            "sweep(address)"
        ];
        for (uint256 i = 0; i < signatures.length; i++) {
            (bool ok,) = address(hook).call(abi.encodeWithSignature(signatures[i], address(this), uint256(1)));
            assertFalse(ok, signatures[i]);
        }
        assertEq(hook.feeSink(), address(sink));
        assertEq(hook.FEE_BPS(), 30);
    }
}
