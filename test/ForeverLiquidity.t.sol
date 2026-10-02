// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {Pool} from "v4-core/src/libraries/Pool.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";

import {TickMath} from "v4-core/src/libraries/TickMath.sol";

import {GotchiFixture} from "./utils/GotchiFixture.sol";
import {ForeverLiquidity} from "../src/ForeverLiquidity.sol";
import {PriceMath} from "../src/PriceMath.sol";

contract ForeverLiquidityTest is GotchiFixture {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    address lp = makeAddr("lp");
    IPoolManager pm;

    function setUp() public override {
        super.setUp();
        pm = IPoolManager(address(manager));
    }

    function test_poolKeyAndConstants() public view {
        PoolKey memory k = forever.poolKey();
        assertEq(Currency.unwrap(k.currency0), address(0));
        assertEq(Currency.unwrap(k.currency1), address(token));
        assertEq(k.fee, 0);
        assertEq(k.tickSpacing, 60);
        assertEq(address(k.hooks), address(hook));
        assertEq(PoolId.unwrap(forever.poolId()), PoolId.unwrap(k.toId()));
        assertEq(forever.TICK_LOWER(), -887_220);
        assertEq(forever.TICK_UPPER(), 887_220);
        assertEq(address(forever.POOL_MANAGER()), address(manager));
        assertEq(address(forever.TOKEN()), address(token));
        assertEq(address(forever.HOOK()), address(hook));
    }

    function test_constructorRejectsZeroAddresses() public {
        vm.expectRevert(ForeverLiquidity.ZeroAddress.selector);
        new ForeverLiquidity(address(0), address(manager), address(hook));
        vm.expectRevert(ForeverLiquidity.ZeroAddress.selector);
        new ForeverLiquidity(address(token), address(0), address(hook));
        vm.expectRevert(ForeverLiquidity.ZeroAddress.selector);
        new ForeverLiquidity(address(token), address(manager), address(0));
    }

    function test_setupSeededTheFullRangePosition() public view {
        (uint128 liquidity,,) = pm.getPositionInfo(forever.poolId(), address(forever), -887_220, 887_220, bytes32(0));
        assertEq(liquidity, seededLiquidity, "position belongs to the ForeverLiquidity contract");
        assertEq(pm.getLiquidity(forever.poolId()), seededLiquidity);
        assertEq(forever.totalLiquidity(), seededLiquidity);
        (uint160 sqrtPriceX96,,,) = pm.getSlot0(forever.poolId());
        assertEq(sqrtPriceX96, forever.sqrtPriceX96ForAmounts(INITIAL_ETH, INITIAL_TOKENS));
        assertEq(address(forever).balance, 0, "keeps no ETH");
        assertEq(token.balanceOf(address(forever)), 0, "keeps no tokens");
    }

    function test_initializeTwiceReverts() public {
        uint160 price = forever.sqrtPriceX96ForAmounts(1, 1);
        vm.expectRevert(Pool.PoolAlreadyInitialized.selector);
        forever.initializePool(price);
    }

    function test_sqrtPriceMath() public view {
        assertEq(forever.sqrtPriceX96ForAmounts(1 ether, 1 ether), 2 ** 96);
        assertEq(forever.sqrtPriceX96ForAmounts(1 ether, 4 ether), 2 * 2 ** 96);
        assertEq(forever.sqrtPriceX96ForAmounts(4 ether, 1 ether), 2 ** 95);
        // 10 ETH for 100,000,000 GOTCHI: 10,000,000 GOTCHI per ETH => sqrt = 3162.27...
        uint160 p = forever.sqrtPriceX96ForAmounts(10 ether, 100_000_000e18);
        uint256 expected = uint256(3_162_277_660) * (uint256(1) << 96) / 1_000_000;
        assertApproxEqRel(uint256(p), expected, 1e12);
    }

    function test_sqrtPriceRejectsZeroAmounts() public {
        vm.expectRevert(ForeverLiquidity.ZeroLiquidity.selector);
        forever.sqrtPriceX96ForAmounts(0, 1);
        vm.expectRevert(ForeverLiquidity.ZeroLiquidity.selector);
        forever.sqrtPriceX96ForAmounts(1, 0);
    }

    function test_sqrtPriceRejectsUnrepresentableAndOutOfRangeRatios() public {
        // 2^64 tokens per wei would overflow the 192-bit ratio: a clean error, not a panic.
        vm.expectRevert(PriceMath.PriceOutOfRange.selector);
        forever.sqrtPriceX96ForAmounts(1, uint256(1) << 64);
        vm.expectRevert(PriceMath.PriceOutOfRange.selector);
        forever.sqrtPriceX96ForAmounts(1, type(uint256).max);
        // Representable but outside the tick range (about 2^-128 tokens per wei).
        vm.expectRevert(PriceMath.PriceOutOfRange.selector);
        forever.sqrtPriceX96ForAmounts(uint256(1) << 130, 1);
        // The extremes that are inside the range work.
        assertGe(forever.sqrtPriceX96ForAmounts(1, (uint256(1) << 64) - 1), TickMath.MIN_SQRT_PRICE);
        assertLt(forever.sqrtPriceX96ForAmounts(1 << 100, 1), TickMath.MAX_SQRT_PRICE);
    }

    function test_addLiquidityWithinEnforcesThePriceBand() public {
        uint160 spot = forever.sqrtPriceX96ForAmounts(INITIAL_ETH, INITIAL_TOKENS);
        uint128 liquidity = forever.liquidityForAmounts(1 ether, 10_000_000e18);
        token.approve(address(forever), type(uint256).max);

        // The pool moved (someone swapped) between quoting and depositing: the guarded call refuses.
        swap(key, true, -1 ether);
        (uint160 moved,,,) = pm.getSlot0(forever.poolId());
        assertTrue(moved != spot);
        vm.expectRevert(abi.encodeWithSelector(ForeverLiquidity.PriceOutsideBounds.selector, moved, spot, spot));
        forever.addLiquidityWithin{value: 1 ether}(liquidity, 10_000_000e18, spot, spot);

        // A band that contains the live price goes through and behaves like addLiquidity.
        uint128 live = forever.liquidityForAmounts(1 ether, 10_000_000e18);
        (uint256 needEth, uint256 needTok) = forever.amountsForLiquidity(live);
        (uint256 usedEth, uint256 usedTok) =
            forever.addLiquidityWithin{value: 1 ether}(live, 10_000_000e18, moved - 1, moved + 1);
        assertEq(usedEth, needEth);
        assertEq(usedTok, needTok);
        assertEq(forever.totalLiquidity(), uint256(seededLiquidity) + live);
    }

    function test_quotedLiquidityFitsTheBudgets() public view {
        uint128 liquidity = forever.liquidityForAmounts(1 ether, 10_000_000e18);
        assertGt(liquidity, 0);
        (uint256 eth, uint256 tok) = forever.amountsForLiquidity(liquidity);
        assertLe(eth, 1 ether);
        assertLe(tok, 10_000_000e18);
        // Within a hair of the budget on the binding side.
        assertGt(eth, 1 ether - 1e9);
    }

    function test_addLiquidityPullsExactAmountsAndRefundsTheRest() public {
        token.transfer(lp, 50_000_000e18);
        vm.deal(lp, 10 ether);
        uint128 liquidity = forever.liquidityForAmounts(1 ether, 10_000_000e18);
        (uint256 needEth, uint256 needTok) = forever.amountsForLiquidity(liquidity);

        vm.startPrank(lp);
        token.approve(address(forever), 20_000_000e18);
        vm.expectEmit(true, false, false, true, address(forever));
        emit ForeverLiquidity.LiquidityLocked(lp, liquidity);
        (uint256 usedEth, uint256 usedTok) = forever.addLiquidity{value: 3 ether}(liquidity, 20_000_000e18);
        vm.stopPrank();

        assertEq(usedEth, needEth);
        assertEq(usedTok, needTok);
        assertEq(lp.balance, 10 ether - needEth, "ETH refunded");
        assertEq(token.balanceOf(lp), 50_000_000e18 - needTok, "tokens refunded");
        assertEq(forever.totalLiquidity(), uint256(seededLiquidity) + liquidity);
        (uint128 positionLiquidity,,) =
            pm.getPositionInfo(forever.poolId(), address(forever), -887_220, 887_220, bytes32(0));
        assertEq(positionLiquidity, seededLiquidity + liquidity, "one shared forever position");
        assertEq(address(forever).balance, 0);
        assertEq(token.balanceOf(address(forever)), 0);
    }

    function test_addLiquidityRevertsWhenUnderfunded() public {
        uint128 liquidity = forever.liquidityForAmounts(1 ether, 10_000_000e18);
        (uint256 needEth, uint256 needTok) = forever.amountsForLiquidity(liquidity);
        token.approve(address(forever), type(uint256).max);

        vm.expectRevert(abi.encodeWithSelector(ForeverLiquidity.InsufficientEth.selector, needEth, needEth - 1));
        forever.addLiquidity{value: needEth - 1}(liquidity, needTok);
        vm.expectRevert(abi.encodeWithSelector(ForeverLiquidity.InsufficientToken.selector, needTok, needTok - 1));
        forever.addLiquidity{value: needEth}(liquidity, needTok - 1);
        vm.expectRevert(ForeverLiquidity.ZeroLiquidity.selector);
        forever.addLiquidity{value: 1 ether}(0, 1);
        // Nothing stuck after the reverts.
        assertEq(token.balanceOf(address(forever)), 0);
        assertEq(address(forever).balance, 0);
    }

    function test_unlockCallbackRefusesEveryoneButTheManager() public {
        vm.expectRevert(ForeverLiquidity.NotPoolManager.selector);
        forever.unlockCallback(abi.encode(ForeverLiquidity.CallbackData(address(this), 1, 1, 1)));
    }

    function test_rejectsStrayEth() public {
        (bool ok,) = address(forever).call{value: 1}("");
        assertFalse(ok);
    }

    function test_hasNoWayToRemoveLiquidity() public {
        string[6] memory signatures = [
            "removeLiquidity(uint128)",
            "removeLiquidity(uint128,uint256)",
            "withdraw()",
            "withdraw(uint256)",
            "collect()",
            "burn(uint128)"
        ];
        for (uint256 i = 0; i < signatures.length; i++) {
            (bool ok,) = address(forever).call(abi.encodeWithSignature(signatures[i], uint128(1), uint256(1)));
            assertFalse(ok, signatures[i]);
        }
        (uint128 liquidity,,) = pm.getPositionInfo(forever.poolId(), address(forever), -887_220, 887_220, bytes32(0));
        assertEq(liquidity, seededLiquidity);
    }

    function test_swapsDoNotAccrueLpFeesToThePosition() public {
        swap(key, true, -1 ether);
        swap(key, false, -1_000_000e18);
        (, uint256 feeGrowth0, uint256 feeGrowth1) =
            pm.getPositionInfo(forever.poolId(), address(forever), -887_220, 887_220, bytes32(0));
        (uint256 global0, uint256 global1) = pm.getFeeGrowthGlobals(forever.poolId());
        assertEq(feeGrowth0, 0);
        assertEq(feeGrowth1, 0);
        assertEq(global0, 0, "zero LP fee: nothing accrues");
        assertEq(global1, 0);
    }
}
