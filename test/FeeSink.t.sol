// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {GotchiFixture} from "./utils/GotchiFixture.sol";
import {MaliciousBaazaar} from "./utils/Mocks.sol";
import {FeeSink} from "../src/FeeSink.sol";
import {FlipEscrow} from "../src/FlipEscrow.sol";
import {GotchiFeeHook} from "../src/GotchiFeeHook.sol";
import {MockBaazaar} from "../src/MockBaazaar.sol";

contract FeeSinkTest is GotchiFixture {
    function test_wiringAndConstants() public view {
        assertEq(sink.MIN_BUY_THRESHOLD(), 0.01 ether);
        assertEq(address(sink.HOOK()), address(hook));
        assertEq(address(sink.BAAZAAR()), address(baazaar));
        assertEq(address(sink.ESCROW()), address(escrow));
        assertEq(sink.pendingPayment(), 0);
    }

    function test_constructorRejectsZeroAddresses() public {
        vm.expectRevert(FeeSink.ZeroAddress.selector);
        new FeeSink(address(0), address(baazaar), address(escrow));
        vm.expectRevert(FeeSink.ZeroAddress.selector);
        new FeeSink(address(hook), address(0), address(escrow));
        vm.expectRevert(FeeSink.ZeroAddress.selector);
        new FeeSink(address(hook), address(baazaar), address(0));
    }

    function test_receiveRecordsAndEmits() public {
        vm.expectEmit(true, false, false, true, address(sink));
        emit FeeSink.FeesCollected(address(this), 1 ether);
        (bool ok,) = address(sink).call{value: 1 ether}("");
        assertTrue(ok);
        assertEq(sink.totalCollected(), 1 ether);
        assertEq(address(sink).balance, 1 ether);
    }

    // ---------------------------------------------------------------------------------------------
    // Threshold and no-buy paths
    // ---------------------------------------------------------------------------------------------

    function test_triggerBuyRevertsBelowThreshold() public {
        mintAndList(seller, 0.001 ether);
        _fund(0.01 ether - 1);
        (bool ok, string memory reason,,,,) = sink.canBuy();
        assertFalse(ok);
        assertEq(reason, "below threshold");
        vm.expectRevert(abi.encodeWithSelector(FeeSink.BelowThreshold.selector, 0.01 ether - 1, 0.01 ether));
        sink.triggerBuy();
    }

    function test_triggerBuyRevertsWithoutListing() public {
        _fund(0.02 ether);
        (bool ok, string memory reason,,,,) = sink.canBuy();
        assertFalse(ok);
        assertEq(reason, "no listing");
        vm.expectRevert(FeeSink.NoListing.selector);
        sink.triggerBuy();
        assertEq(address(sink).balance, 0.02 ether, "nothing left the sink");
    }

    function test_triggerBuyRevertsWhenCheapestIsUnaffordable() public {
        mintAndList(seller, 0.05 ether);
        _fund(0.02 ether);
        (bool ok, string memory reason,,, uint256 price,) = sink.canBuy();
        assertFalse(ok);
        assertEq(reason, "cannot afford cheapest listing");
        assertEq(price, 0.05 ether);
        vm.expectRevert(abi.encodeWithSelector(FeeSink.CannotAfford.selector, 0.05 ether, 0.02 ether));
        sink.triggerBuy();
    }

    // ---------------------------------------------------------------------------------------------
    // Successful buy
    // ---------------------------------------------------------------------------------------------

    function test_triggerBuyBuysTheCheapestForTheEscrow() public {
        (, uint256 expensiveId) = mintAndList(seller, 0.005 ether);
        (uint256 cheapListing, uint256 cheapId) = mintAndList(seller, 0.004 ether);
        _fund(0.02 ether);

        (bool ok,, uint256 listingId, uint256 tokenId, uint256 price, address listSeller) = sink.canBuy();
        assertTrue(ok);
        assertEq(listingId, cheapListing);
        assertEq(tokenId, cheapId);
        assertEq(price, 0.004 ether);
        assertEq(listSeller, seller);

        vm.expectEmit(true, false, false, true, address(sink));
        emit FeeSink.BuyTriggered(cheapListing, 0.004 ether, cheapId);
        vm.expectEmit(true, false, false, true, address(escrow));
        emit FlipEscrow.AcquisitionReceived(0, cheapId);
        uint256 acquisitionId = sink.triggerBuy();

        assertEq(acquisitionId, 0);
        assertEq(nft.ownerOf(cheapId), address(escrow), "escrow holds the bought gotchi");
        assertEq(nft.ownerOf(expensiveId), address(baazaar), "the dearer one stays listed");
        assertEq(baazaar.proceeds(seller), 0.004 ether, "seller is credited");
        assertEq(address(sink).balance, 0.016 ether);
        assertEq(sink.totalSpent(), 0.004 ether);
        assertEq(sink.buyCount(), 1);
        assertEq(sink.pendingPayment(), 0);
        assertEq(uint8(escrow.getAcquisition(0).status), uint8(FlipEscrow.Status.Pending));
        assertEq(escrow.acquisitionCount(), 1);
    }

    function test_triggerBuyCanRunAgainWhileAffordable() public {
        mintAndList(seller, 0.005 ether);
        mintAndList(seller, 0.004 ether);
        _fund(0.02 ether);
        sink.triggerBuy();
        assertEq(sink.triggerBuy(), 1);
        assertEq(address(sink).balance, 0.011 ether);
        vm.expectRevert(FeeSink.NoListing.selector);
        sink.triggerBuy();
    }

    // ---------------------------------------------------------------------------------------------
    // Payment callback and reentrancy
    // ---------------------------------------------------------------------------------------------

    function test_payForListingRefusesEveryoneButTheBaazaar() public {
        _fund(1 ether);
        vm.expectRevert(FeeSink.NotBaazaar.selector);
        sink.payForListing(1, 1);
    }

    function test_payForListingRefusesUnarmedPayments() public {
        _fund(1 ether);
        vm.prank(address(baazaar));
        vm.expectRevert(abi.encodeWithSelector(FeeSink.UnexpectedPayment.selector, 1, 0));
        sink.payForListing(1, 1);
        vm.prank(address(baazaar));
        vm.expectRevert(abi.encodeWithSelector(FeeSink.UnexpectedPayment.selector, 0, 0));
        sink.payForListing(1, 0);
        assertEq(address(sink).balance, 1 ether);
    }

    function test_reentrancyFromInsideThePaymentIsRefused() public {
        MaliciousBaazaar evil = new MaliciousBaazaar();
        GotchiFeeHook freshHook = new GotchiFeeHook(address(manager));
        FeeSink victim = new FeeSink(address(freshHook), address(evil), address(escrow));
        evil.arm(victim, 0.004 ether, 7);
        vm.deal(address(victim), 0.02 ether);

        victim.triggerBuy();

        assertTrue(evil.reenterTriggerBuyReverted(), "re-entering triggerBuy must revert");
        assertTrue(evil.secondPaymentReverted(), "a second payment must revert");
        assertEq(evil.paidTotal(), 0.004 ether, "paid exactly once");
        assertEq(address(victim).balance, 0.016 ether);
        assertEq(victim.pendingPayment(), 0);
    }

    function test_reentrancyAttemptRevertsWithTheGuardError() public {
        MaliciousBaazaar evil = new MaliciousBaazaar();
        GotchiFeeHook freshHook = new GotchiFeeHook(address(manager));
        FeeSink victim = new FeeSink(address(freshHook), address(evil), address(escrow));
        evil.arm(victim, 0.004 ether, 7);
        vm.deal(address(victim), 0.02 ether);
        // The guard is what stops the nested call: calling as the baazaar outside a crank is refused
        // for a different reason (nothing armed), proving the two checks are independent.
        vm.prank(address(evil));
        vm.expectRevert(abi.encodeWithSelector(FeeSink.UnexpectedPayment.selector, 0.004 ether, 0));
        victim.payForListing(1, 0.004 ether);
    }

    function test_cannotBeDrainedBySendingDirectly() public {
        _fund(1 ether);
        (bool ok,) = address(sink).call(abi.encodeWithSignature("withdraw()"));
        assertFalse(ok);
        (ok,) = address(sink).call(abi.encodeWithSignature("withdraw(uint256)", 1 ether));
        assertFalse(ok);
        assertEq(address(sink).balance, 1 ether);
    }

    function _fund(uint256 amount) internal {
        (bool ok,) = address(sink).call{value: amount}("");
        assertTrue(ok);
    }
}
