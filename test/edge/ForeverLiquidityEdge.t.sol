// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {Pool} from "v4-core/src/libraries/Pool.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {GotchiFixture} from "../utils/GotchiFixture.sol";
import {GotchiFeeHook} from "../../src/GotchiFeeHook.sol";
import {ForeverLiquidity} from "../../src/ForeverLiquidity.sol";
import {PriceMath} from "../../src/PriceMath.sol";

/// @notice A depositor that cannot take an ETH refund.
contract NoRefundDepositor {
    function add(ForeverLiquidity forever, IERC20 token, uint128 liquidity, uint256 maxToken, uint256 value)
        external
        returns (uint256, uint256)
    {
        token.approve(address(forever), maxToken);
        return forever.addLiquidity{value: value}(liquidity, maxToken);
    }
}

/// @notice ForeverLiquidity edges: uninitialized pool, the initialization race, refund failures and
/// quoting at random budgets.
/// forge-config: default.fuzz.runs = 256
contract ForeverLiquidityEdgeTest is GotchiFixture {
    using StateLibrary for IPoolManager;

    function _fresh() internal returns (ForeverLiquidity fresh) {
        GotchiFeeHook freshHook = deployHook(address(manager), uint256(lastHookSalt) + 1);
        fresh = new ForeverLiquidity(address(token), address(manager), address(freshHook));
    }

    function test_quotesAndDepositsRevertBeforeThePoolIsInitialized() public {
        ForeverLiquidity fresh = _fresh();
        vm.expectRevert(ForeverLiquidity.PoolNotInitialized.selector);
        fresh.amountsForLiquidity(1);
        vm.expectRevert(ForeverLiquidity.PoolNotInitialized.selector);
        fresh.liquidityForAmounts(1 ether, 1e18);
        token.approve(address(fresh), 1e18);
        vm.expectRevert(ForeverLiquidity.PoolNotInitialized.selector);
        fresh.addLiquidity{value: 1 ether}(1e18, 1e18);
        assertEq(token.balanceOf(address(fresh)), 0, "tokens refunded by the revert");
        assertEq(fresh.totalLiquidity(), 0);
    }

    function test_initializationIsPermissionlessAndFinal() public {
        ForeverLiquidity fresh = _fresh();
        address stranger = makeAddr("stranger");
        uint160 strangerPrice = fresh.sqrtPriceX96ForAmounts(1 ether, 1e18);
        vm.prank(stranger);
        fresh.initializePool(strangerPrice);
        (uint160 price,,,) = IPoolManager(address(manager)).getSlot0(fresh.poolId());
        assertEq(price, strangerPrice, "whoever calls first sets the opening price");
        uint160 intendedPrice = fresh.sqrtPriceX96ForAmounts(INITIAL_ETH, INITIAL_TOKENS);
        vm.expectRevert(Pool.PoolAlreadyInitialized.selector);
        fresh.initializePool(intendedPrice);
        // A depositor is still protected from paying more than they offered at the stranger's price.
        uint128 liquidity = fresh.liquidityForAmounts(1 ether, 1e18);
        (uint256 needEth, uint256 needTok) = fresh.amountsForLiquidity(liquidity);
        assertLe(needEth, 1 ether);
        assertLe(needTok, 1e18);
    }

    function test_depositorThatCannotTakeARefundIsRefusedWhenThereIsExcess() public {
        NoRefundDepositor depositor = new NoRefundDepositor();
        vm.deal(address(depositor), 10 ether);
        token.transfer(address(depositor), 50_000_000e18);
        uint128 liquidity = forever.liquidityForAmounts(1 ether, 10_000_000e18);
        (uint256 needEth, uint256 needTok) = forever.amountsForLiquidity(liquidity);

        vm.expectRevert(ForeverLiquidity.RefundFailed.selector);
        depositor.add(forever, token, liquidity, needTok, needEth + 1);
        assertEq(forever.totalLiquidity(), seededLiquidity, "nothing was added");

        // With the exact ETH there is nothing to refund and the deposit goes through.
        (uint256 usedEth, uint256 usedTok) = depositor.add(forever, token, liquidity, needTok, needEth);
        assertEq(usedEth, needEth);
        assertEq(usedTok, needTok);
        assertEq(address(depositor).balance, 10 ether - needEth);
        assertEq(token.balanceOf(address(depositor)), 50_000_000e18 - needTok);
        assertEq(forever.totalLiquidity(), uint256(seededLiquidity) + liquidity);
    }

    function testFuzz_quotedLiquidityNeverExceedsEitherBudget(uint256 ethBudget, uint256 tokenBudget) public view {
        ethBudget = bound(ethBudget, 1e9, 1_000 ether);
        tokenBudget = bound(tokenBudget, 1e12, 1e27);
        uint128 liquidity = forever.liquidityForAmounts(ethBudget, tokenBudget);
        assertGt(liquidity, 0, "a positive budget on both sides buys some liquidity");
        (uint256 eth, uint256 tok) = forever.amountsForLiquidity(liquidity);
        assertLe(eth, ethBudget, "ETH within budget");
        assertLe(tok, tokenBudget, "tokens within budget");
    }

    function testFuzz_addLiquidityChargesExactlyTheQuoteAndRefundsTheRest(uint256 ethBudget, uint256 slack) public {
        ethBudget = bound(ethBudget, 1e12, 5 ether);
        slack = bound(slack, 0, 1 ether);
        uint256 tokenBudget = ethBudget * 10_000_000;
        uint128 liquidity = forever.liquidityForAmounts(ethBudget, tokenBudget);
        (uint256 needEth, uint256 needTok) = forever.amountsForLiquidity(liquidity);
        uint256 ethBefore = address(this).balance;
        uint256 tokBefore = token.balanceOf(address(this));
        token.approve(address(forever), tokenBudget + slack);
        (uint256 usedEth, uint256 usedTok) =
            forever.addLiquidity{value: ethBudget + slack}(liquidity, tokenBudget + slack);
        assertEq(usedEth, needEth);
        assertEq(usedTok, needTok);
        assertEq(ethBefore - address(this).balance, needEth, "only the quoted ETH was kept");
        assertEq(tokBefore - token.balanceOf(address(this)), needTok, "only the quoted tokens were kept");
        assertEq(address(forever).balance, 0);
        assertEq(token.balanceOf(address(forever)), 0);
    }

    function test_unlockCallbackCannotBeDrivenOutsideAnUnlock() public {
        bytes memory data = abi.encode(ForeverLiquidity.CallbackData(address(this), 1, 1 ether, 1e18));
        vm.prank(address(manager));
        vm.expectRevert();
        forever.unlockCallback(data);
        assertEq(forever.totalLiquidity(), seededLiquidity);
    }

    /// @dev The quote computes `tokenAmount * 2^192 / ethAmount`. Token-per-wei ratios of 2^64 and above
    /// would overflow the 256-bit intermediate, so they are refused up front with `PriceOutOfRange` (never
    /// an arithmetic panic), and so is any ratio whose square root falls outside the pool's tick range.
    /// Ratios inside the range quote a price the pool accepts, in both directions.
    function test_sqrtPriceQuoteRejectsRatiosBeyondItsRangeAndQuotesTheRest() public {
        // One ETH for the whole supply (1e9 tokens per wei of ETH) is far inside the range.
        assertGt(forever.sqrtPriceX96ForAmounts(1 ether, 1e27), 0);
        // The whole supply in wei of ETH for one wei of token: a tiny but positive price.
        assertGt(forever.sqrtPriceX96ForAmounts(1e27, 1), 0);
        // Exactly 2^64 - 1 tokens per wei still fits.
        assertGt(forever.sqrtPriceX96ForAmounts(1, type(uint64).max), 0);
        // 2^64 tokens per wei would overflow the intermediate and is refused with the named error.
        vm.expectRevert(PriceMath.PriceOutOfRange.selector);
        forever.sqrtPriceX96ForAmounts(1, uint256(type(uint64).max) + 1);
        vm.expectRevert(PriceMath.PriceOutOfRange.selector);
        forever.sqrtPriceX96ForAmounts(1, type(uint256).max);
        // A price below the lowest tick (1e39 wei of ETH per wei of token) is refused the same way.
        vm.expectRevert(PriceMath.PriceOutOfRange.selector);
        forever.sqrtPriceX96ForAmounts(1e39, 1);
        // Zero on either side is a zero-liquidity error, checked before the ratio.
        vm.expectRevert(ForeverLiquidity.ZeroLiquidity.selector);
        forever.sqrtPriceX96ForAmounts(0, 1);
        vm.expectRevert(ForeverLiquidity.ZeroLiquidity.selector);
        forever.sqrtPriceX96ForAmounts(1, 0);
    }

    /// @dev For any pair of amounts the quote either reverts with one of its two named errors or returns a
    /// price inside the pool's tick range; it never panics.
    function testFuzz_sqrtPriceQuoteEitherNamesItsErrorOrQuotesInsideTheTickRange(
        uint256 ethAmount,
        uint256 tokenAmount
    ) public view {
        try forever.sqrtPriceX96ForAmounts(ethAmount, tokenAmount) returns (uint160 price) {
            assertGe(price, TickMath.MIN_SQRT_PRICE, "quoted below the lowest tick");
            assertLt(price, TickMath.MAX_SQRT_PRICE, "quoted at or above the highest tick");
            assertTrue(ethAmount > 0 && tokenAmount > 0, "a zero amount produced a quote");
            assertLt(tokenAmount / ethAmount, uint256(1) << 64, "an overflowing ratio produced a quote");
        } catch (bytes memory err) {
            bytes4 selector = bytes4(err);
            if (ethAmount == 0 || tokenAmount == 0) {
                assertEq(selector, ForeverLiquidity.ZeroLiquidity.selector, "zero amount: wrong error");
            } else {
                assertEq(selector, PriceMath.PriceOutOfRange.selector, "non-zero amounts: not the named error");
            }
        }
    }

    // ---------------------------------------------------------------------------------------------
    // Price band deposits
    // ---------------------------------------------------------------------------------------------

    function test_addLiquidityWithinAcceptsAnExactBandAndRefusesOneWeiOutsideIt() public {
        (uint160 spot,,,) = IPoolManager(address(manager)).getSlot0(forever.poolId());
        uint128 liquidity = forever.liquidityForAmounts(1 ether, 10_000_000e18);
        (uint256 needEth, uint256 needTok) = forever.amountsForLiquidity(liquidity);
        token.approve(address(forever), type(uint256).max);

        // Band entirely above the spot price.
        vm.expectRevert(
            abi.encodeWithSelector(ForeverLiquidity.PriceOutsideBounds.selector, spot, spot + 1, type(uint160).max)
        );
        forever.addLiquidityWithin{value: needEth}(liquidity, needTok, spot + 1, type(uint160).max);
        // Band entirely below the spot price.
        vm.expectRevert(abi.encodeWithSelector(ForeverLiquidity.PriceOutsideBounds.selector, spot, 0, spot - 1));
        forever.addLiquidityWithin{value: needEth}(liquidity, needTok, 0, spot - 1);
        // An inverted band can never match.
        vm.expectRevert(abi.encodeWithSelector(ForeverLiquidity.PriceOutsideBounds.selector, spot, spot + 1, spot - 1));
        forever.addLiquidityWithin{value: needEth}(liquidity, needTok, spot + 1, spot - 1);
        assertEq(forever.totalLiquidity(), seededLiquidity, "nothing was added by the refused deposits");
        assertEq(token.balanceOf(address(forever)), 0, "a refused deposit pulled no tokens");

        // The degenerate band [spot, spot] is accepted and charges exactly the quote.
        uint256 ethBefore = address(this).balance;
        (uint256 usedEth, uint256 usedTok) = forever.addLiquidityWithin{value: needEth}(liquidity, needTok, spot, spot);
        assertEq(usedEth, needEth);
        assertEq(usedTok, needTok);
        assertEq(ethBefore - address(this).balance, needEth);
        assertEq(forever.totalLiquidity(), uint256(seededLiquidity) + liquidity);
    }

    function test_addLiquidityWithinRefusesAfterASwapMovesThePriceOutOfTheBand() public {
        (uint160 spot,,,) = IPoolManager(address(manager)).getSlot0(forever.poolId());
        uint128 liquidity = forever.liquidityForAmounts(1 ether, 10_000_000e18);
        (uint256 needEth, uint256 needTok) = forever.amountsForLiquidity(liquidity);
        token.approve(address(forever), type(uint256).max);

        // Someone buys GOTCHI first: the pool leaves the price the band was quoted at a moment ago.
        swap(key, true, -1 ether);
        (uint160 moved,,,) = IPoolManager(address(manager)).getSlot0(forever.poolId());
        assertTrue(moved != spot, "the swap moved the price");
        vm.expectRevert(abi.encodeWithSelector(ForeverLiquidity.PriceOutsideBounds.selector, moved, spot, spot));
        forever.addLiquidityWithin{value: needEth}(liquidity, needTok, spot, spot);
        assertEq(forever.totalLiquidity(), seededLiquidity);

        // Re-quoting at the moved price goes through; the unguarded `addLiquidity` always did.
        uint128 live = forever.liquidityForAmounts(1 ether, 10_000_000e18);
        (uint256 liveEth, uint256 liveTok) = forever.amountsForLiquidity(live);
        forever.addLiquidityWithin{value: liveEth}(live, liveTok, moved, moved);
        assertEq(forever.totalLiquidity(), uint256(seededLiquidity) + live);
    }
}
