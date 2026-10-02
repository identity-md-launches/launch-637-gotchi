// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {stdError} from "forge-std/StdError.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {Pool} from "v4-core/src/libraries/Pool.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {GotchiFixture} from "../utils/GotchiFixture.sol";
import {GotchiFeeHook} from "../../src/GotchiFeeHook.sol";
import {ForeverLiquidity} from "../../src/ForeverLiquidity.sol";

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

    /// @dev The quote computes `tokenAmount * 2^192 / ethAmount`, so token-per-wei ratios of 2^64 and
    /// above overflow and revert with an arithmetic panic before the uint160 check is reached. A revert is
    /// the right answer for such a ratio; the explicit `PriceOutOfRange` error is simply never the one
    /// seen. Ratios inside the range quote a positive price in both directions.
    function test_sqrtPriceQuoteRejectsRatiosBeyondItsRangeAndQuotesTheRest() public {
        // One ETH for the whole supply (1e9 tokens per wei of ETH) is far inside the range.
        assertGt(forever.sqrtPriceX96ForAmounts(1 ether, 1e27), 0);
        // The whole supply in wei of ETH for one wei of token: a tiny but positive price.
        assertGt(forever.sqrtPriceX96ForAmounts(1e27, 1), 0);
        // Exactly 2^64 - 1 tokens per wei still fits.
        assertGt(forever.sqrtPriceX96ForAmounts(1, type(uint64).max), 0);
        // 2^64 tokens per wei overflows the 256-bit intermediate and is refused.
        vm.expectRevert(stdError.arithmeticError);
        forever.sqrtPriceX96ForAmounts(1, uint256(type(uint64).max) + 1);
        vm.expectRevert(stdError.arithmeticError);
        forever.sqrtPriceX96ForAmounts(1, type(uint256).max);
    }
}
