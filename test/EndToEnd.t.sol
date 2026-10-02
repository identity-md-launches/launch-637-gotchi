// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";

import {GotchiFixture} from "./utils/GotchiFixture.sol";
import {GotchiFeeHook} from "../src/GotchiFeeHook.sol";
import {FeeSink} from "../src/FeeSink.sol";
import {FlipEscrow} from "../src/FlipEscrow.sol";
import {MockBaazaar} from "../src/MockBaazaar.sol";

/// @notice Fees -> buy -> flip, end to end, with the full event trail asserted.
contract EndToEndTest is GotchiFixture {
    using PoolIdLibrary for PoolKey;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");

    // Scenario state kept in storage so each stage stays small.
    uint256 dearListing;
    uint256 dearId;
    uint256 cheapListing;
    uint256 cheapId;
    bytes32 secretBurn;
    bytes32 hashBurn;
    bytes32 secretDrop;
    bytes32 hashDrop;

    function test_feesBuyAndFlipEndToEnd() public {
        _stageHoldersInventoryAndCommitments();
        _stageFeesAndFirstBuy();
        _stageNoBuyBelowThresholdThenSecondBuy();
        _stageFlips();
        _stageBooks();
    }

    function _stageHoldersInventoryAndCommitments() internal {
        fundAndRegister(alice, 1_000e18);
        fundAndRegister(bob, 3_000e18);
        fundAndRegister(carol, 6_000e18);
        assertEq(picker.totalWeight(), 10_000e18);

        (dearListing, dearId) = mintAndList(seller, 0.006 ether);
        (cheapListing, cheapId) = mintAndList(seller, 0.004 ether);

        // Acquisition 0 will be the cheap gotchi (burn roll), acquisition 1 the dear one (airdrop roll).
        (secretBurn, hashBurn) = findSecret(0, cheapId, 0, true);
        (secretDrop, hashDrop) = findSecret(1, dearId, 1, false);
        vm.startPrank(operator);
        escrow.commit(hashBurn);
        escrow.commit(hashDrop);
        vm.stopPrank();
        vm.roll(block.number + 1);
    }

    function _stageFeesAndFirstBuy() internal {
        uint256 fee = 0.012 ether;
        vm.expectEmit(true, true, false, true, address(hook));
        emit GotchiFeeHook.HookFeeTaken(key.toId(), address(sink), fee);
        vm.expectEmit(true, false, false, true, address(sink));
        emit FeeSink.FeesCollected(address(manager), fee);
        BalanceDelta delta = swap(key, true, -4 ether);
        assertEq(delta.amount0(), -4 ether);
        assertEq(address(sink).balance, fee);

        vm.expectEmit(true, false, false, true, address(sink));
        emit FeeSink.BuyTriggered(cheapListing, 0.004 ether, cheapId);
        vm.expectEmit(true, true, false, true, address(baazaar));
        emit MockBaazaar.Sold(cheapListing, cheapId, 0.004 ether, seller, address(sink), address(escrow));
        vm.expectEmit(true, false, false, true, address(escrow));
        emit FlipEscrow.AcquisitionReceived(0, cheapId);
        vm.expectEmit(true, false, false, true, address(escrow));
        emit FlipEscrow.FlipRequested(0, cheapId, escrow.computeRequestId(0, cheapId, 0, hashBurn));
        assertEq(sink.triggerBuy(), 0);

        assertEq(nft.ownerOf(cheapId), address(escrow));
        assertEq(baazaar.proceeds(seller), 0.004 ether);
        assertEq(address(sink).balance, 0.008 ether);
    }

    function _stageNoBuyBelowThresholdThenSecondBuy() internal {
        vm.expectRevert(abi.encodeWithSelector(FeeSink.BelowThreshold.selector, 0.008 ether, 0.01 ether));
        sink.triggerBuy();
        assertEq(nft.ownerOf(dearId), address(baazaar), "dear gotchi still listed");

        swap(key, false, 1 ether); // exact-output ETH: 0.003 ETH fee
        assertEq(address(sink).balance, 0.011 ether);
        vm.expectEmit(true, false, false, true, address(sink));
        emit FeeSink.BuyTriggered(dearListing, 0.006 ether, dearId);
        vm.expectEmit(true, false, false, true, address(escrow));
        emit FlipEscrow.FlipRequested(1, dearId, escrow.computeRequestId(1, dearId, 1, hashDrop));
        assertEq(sink.triggerBuy(), 1);
        assertEq(address(sink).balance, 0.005 ether);
        assertEq(sink.buyCount(), 2);
        assertEq(sink.totalSpent(), 0.01 ether);
        assertEq(baazaar.activeCount(), 0);
    }

    function _stageFlips() internal {
        // Flip 0 burns.
        vm.expectEmit(true, true, false, true, address(escrow));
        emit FlipEscrow.FlipResolved(0, cheapId, true, DEAD);
        vm.expectEmit(true, true, false, true, address(escrow));
        emit FlipEscrow.Burned(cheapId, DEAD);
        escrow.reveal(0, secretBurn);
        assertEq(nft.ownerOf(cheapId), DEAD);

        // Flip 1 airdrops to the weighted pick.
        uint256 roll = escrow.rollFor(secretDrop, escrow.getAcquisition(1).requestId);
        (address winner, uint256 weight) = picker.pick(roll);
        assertTrue(winner == alice || winner == bob || winner == carol);
        assertEq(weight, token.balanceOf(winner));
        vm.expectEmit(true, true, false, true, address(escrow));
        emit FlipEscrow.FlipResolved(1, dearId, false, winner);
        vm.expectEmit(true, true, false, true, address(escrow));
        emit FlipEscrow.Airdropped(dearId, winner, weight);
        escrow.reveal(1, secretDrop);
        assertEq(nft.ownerOf(dearId), winner);
    }

    function _stageBooks() internal {
        vm.prank(seller);
        baazaar.withdrawProceeds();
        assertEq(seller.balance, 0.01 ether);
        assertEq(address(baazaar).balance, 0);
        assertEq(address(hook).balance, 0);
        assertEq(address(escrow).balance, 0);
        assertEq(sink.totalCollected(), 0.015 ether);
        assertEq(sink.totalCollected() - sink.totalSpent(), address(sink).balance, "sink conserves ETH");
    }

    function test_flipResolvesByForcedBurnWhenTheOperatorNeverReveals() public {
        mintAndList(seller, 0.004 ether);
        vm.prank(operator);
        escrow.commit(keccak256("the operator will lose this"));
        vm.roll(block.number + 1);
        swap(key, true, -4 ether);
        uint256 acquisitionId = sink.triggerBuy();
        uint256 tokenId = escrow.getAcquisition(acquisitionId).tokenId;
        assertEq(uint8(escrow.getAcquisition(acquisitionId).status), uint8(FlipEscrow.Status.Requested));

        vm.roll(block.number + escrow.REVEAL_WINDOW_BLOCKS() + 1);
        vm.expectEmit(true, true, false, true, address(escrow));
        emit FlipEscrow.FlipResolved(acquisitionId, tokenId, true, DEAD);
        escrow.expire(acquisitionId);
        assertEq(nft.ownerOf(tokenId), DEAD);
    }

    function test_buyWithoutAnyCommitmentWaitsThenBurnsOnTimeout() public {
        mintAndList(seller, 0.004 ether);
        swap(key, true, -4 ether);
        uint256 acquisitionId = sink.triggerBuy();
        uint256 tokenId = escrow.getAcquisition(acquisitionId).tokenId;
        assertEq(uint8(escrow.getAcquisition(acquisitionId).status), uint8(FlipEscrow.Status.Pending));
        vm.expectRevert(FlipEscrow.NoCommitmentAvailable.selector);
        escrow.requestFlip(acquisitionId);

        vm.roll(block.number + escrow.PENDING_TIMEOUT_BLOCKS() + 1);
        escrow.expire(acquisitionId);
        assertEq(nft.ownerOf(tokenId), DEAD);
    }
}
