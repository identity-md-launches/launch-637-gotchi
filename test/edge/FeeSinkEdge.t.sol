// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC721Errors} from "@openzeppelin/contracts/interfaces/IERC6093.sol";
import {GotchiFixture} from "../utils/GotchiFixture.sol";
import {FeeSink} from "../../src/FeeSink.sol";
import {FlipEscrow} from "../../src/FlipEscrow.sol";
import {MockBaazaar} from "../../src/MockBaazaar.sol";

/// @notice A keeper that is a contract, to show the crank is not EOA-only.
contract Keeper {
    function crank(FeeSink sink) external returns (uint256) {
        return sink.triggerBuy();
    }
}

/// @notice Boundaries and unusual callers for the FeeSink.
/// forge-config: default.fuzz.runs = 512
contract FeeSinkEdgeTest is GotchiFixture {
    address buyer = makeAddr("buyer");

    function test_balanceExactlyAtThresholdBuysAndAPriceEqualToTheBalanceSpendsEverything() public {
        (uint256 listingId, uint256 tokenId) = mintAndList(seller, 0.01 ether);
        _fund(0.01 ether);
        (bool ok,, uint256 quotedListing,, uint256 price,) = sink.canBuy();
        assertTrue(ok, "exactly the threshold is enough");
        assertEq(quotedListing, listingId);
        assertEq(price, 0.01 ether);

        sink.triggerBuy();
        assertEq(address(sink).balance, 0, "the whole balance went to the purchase");
        assertEq(nft.ownerOf(tokenId), address(escrow));
        assertEq(baazaar.proceeds(seller), 0.01 ether);
        string memory reason;
        (ok, reason,,,,) = sink.canBuy();
        assertFalse(ok);
        assertEq(reason, "below threshold");
    }

    function test_oneWeiBelowThresholdNeverBuysEvenAOneWeiListing() public {
        mintAndList(seller, 1);
        _fund(0.01 ether - 1);
        vm.expectRevert(abi.encodeWithSelector(FeeSink.BelowThreshold.selector, 0.01 ether - 1, 0.01 ether));
        sink.triggerBuy();
        assertEq(baazaar.activeCount(), 1, "listing untouched");
    }

    function test_oneWeiListingIsBoughtForOneWei() public {
        (uint256 listingId, uint256 tokenId) = mintAndList(seller, 1);
        _fund(0.01 ether);
        vm.expectEmit(true, false, false, true, address(sink));
        emit FeeSink.BuyTriggered(listingId, 1, tokenId);
        sink.triggerBuy();
        assertEq(address(sink).balance, 0.01 ether - 1);
        assertEq(sink.totalSpent(), 1);
        assertEq(baazaar.proceeds(seller), 1);
    }

    function test_cheapestChangingBeforeTheCrankRunsIsHandled() public {
        (uint256 cheapListing, uint256 cheapId) = mintAndList(seller, 0.004 ether);
        (uint256 dearListing, uint256 dearId) = mintAndList(seller, 0.006 ether);
        _fund(0.02 ether);
        (,, uint256 quoted,,,) = sink.canBuy();
        assertEq(quoted, cheapListing, "the cheap one is quoted");

        // Somebody else buys the cheap one first.
        vm.deal(buyer, 1 ether);
        vm.prank(buyer);
        baazaar.buyCheapest{value: 0.004 ether}(buyer, 0.004 ether);
        assertEq(nft.ownerOf(cheapId), buyer);

        // The crank now buys the next cheapest and reports it, not the stale quote.
        vm.expectEmit(true, false, false, true, address(sink));
        emit FeeSink.BuyTriggered(dearListing, 0.006 ether, dearId);
        sink.triggerBuy();
        assertEq(nft.ownerOf(dearId), address(escrow));
        assertEq(address(sink).balance, 0.014 ether);
        assertEq(sink.totalSpent(), 0.006 ether);

        vm.expectRevert(FeeSink.NoListing.selector);
        sink.triggerBuy();
    }

    /// @dev `canBuy` must agree with `triggerBuy` for any balance and any (or no) listing.
    function testFuzz_canBuyPredictsTriggerBuy(uint256 balance, uint256 price, bool listed) public {
        balance = bound(balance, 0, 0.05 ether);
        price = bound(price, 1, 0.05 ether);
        uint256 tokenId = 0;
        if (listed) (, tokenId) = mintAndList(seller, price);
        if (balance > 0) _fund(balance);

        (bool ok, string memory reason,,, uint256 quotedPrice,) = sink.canBuy();
        bool expected = balance >= 0.01 ether && listed && price <= balance;
        assertEq(ok, expected, "canBuy prediction");
        if (!expected) {
            if (balance < 0.01 ether) assertEq(reason, "below threshold");
            else if (!listed) assertEq(reason, "no listing");
            else assertEq(reason, "cannot afford cheapest listing");
        }

        if (expected) {
            sink.triggerBuy();
            assertEq(address(sink).balance, balance - quotedPrice, "paid exactly the quoted price");
            assertEq(nft.ownerOf(tokenId), address(escrow));
            assertEq(sink.totalSpent(), price);
        } else {
            vm.expectRevert();
            sink.triggerBuy();
            assertEq(address(sink).balance, balance, "a refused crank moves nothing");
            assertEq(sink.totalSpent(), 0);
            assertEq(sink.buyCount(), 0);
        }
        assertEq(sink.pendingPayment(), 0);
    }

    function test_donationsCountAsCollectedAndNameTheSenderAsPool() public {
        vm.deal(buyer, 1 ether);
        vm.prank(buyer);
        vm.expectEmit(true, false, false, true, address(sink));
        emit FeeSink.FeesCollected(buyer, 0.5 ether);
        (bool ok,) = address(sink).call{value: 0.5 ether}("");
        assertTrue(ok);
        assertEq(sink.totalCollected(), 0.5 ether);
        // Donations are spent exactly like fees.
        mintAndList(seller, 0.4 ether);
        sink.triggerBuy();
        assertEq(address(sink).balance, 0.1 ether);
    }

    function test_noAdminSelectorMovesEthOrChangesWiring() public {
        _fund(1 ether);
        string[8] memory signatures = [
            "withdraw()",
            "withdraw(uint256)",
            "sweep(address)",
            "rescue(address,uint256)",
            "setThreshold(uint256)",
            "setBaazaar(address)",
            "setEscrow(address)",
            "transferOwnership(address)"
        ];
        for (uint256 i = 0; i < signatures.length; i++) {
            (bool ok,) = address(sink).call(abi.encodeWithSignature(signatures[i], address(this), uint256(1)));
            assertFalse(ok, signatures[i]);
        }
        assertEq(address(sink).balance, 1 ether);
        assertEq(address(sink.BAAZAAR()), address(baazaar));
        assertEq(address(sink.ESCROW()), address(escrow));
        assertEq(sink.MIN_BUY_THRESHOLD(), 0.01 ether);
    }

    function test_aContractKeeperCanCrank() public {
        (, uint256 tokenId) = mintAndList(seller, 0.004 ether);
        _fund(0.02 ether);
        Keeper keeper = new Keeper();
        assertEq(keeper.crank(sink), 0);
        assertEq(nft.ownerOf(tokenId), address(escrow));
    }

    function test_sinkRefusesNftsSentToIt() public {
        vm.prank(minter);
        uint256 id = nft.mint(seller);
        vm.prank(seller);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721InvalidReceiver.selector, address(sink)));
        nft.safeTransferFrom(seller, address(sink), id);
    }

    function test_twoCranksInOneBlockBuyTwoDifferentGotchis() public {
        (, uint256 a) = mintAndList(seller, 0.003 ether);
        (, uint256 b) = mintAndList(seller, 0.003 ether);
        _fund(0.02 ether);
        uint256 first = sink.triggerBuy();
        uint256 second = sink.triggerBuy();
        assertEq(first, 0);
        assertEq(second, 1);
        assertEq(escrow.getAcquisition(0).tokenId, a, "ties go to the older listing first");
        assertEq(escrow.getAcquisition(1).tokenId, b);
        assertEq(uint8(escrow.getAcquisition(0).status), uint8(FlipEscrow.Status.Pending));
        assertEq(uint8(escrow.getAcquisition(1).status), uint8(FlipEscrow.Status.Pending));
    }

    function _fund(uint256 amount) internal {
        (bool ok,) = address(sink).call{value: amount}("");
        assertTrue(ok);
    }
}
