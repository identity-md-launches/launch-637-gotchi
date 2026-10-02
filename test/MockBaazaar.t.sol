// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC721Errors} from "@openzeppelin/contracts/interfaces/IERC6093.sol";
import {GotchiFixture} from "./utils/GotchiFixture.sol";
import {CallbackBuyer, StingyBuyer, RevertingReceiver} from "./utils/Mocks.sol";
import {MockBaazaar} from "../src/MockBaazaar.sol";
import {MockAavegotchi} from "../src/MockAavegotchi.sol";

contract MockBaazaarTest is GotchiFixture {
    address buyer = makeAddr("buyer");

    function setUp() public override {
        super.setUp();
        vm.deal(buyer, 100 ether);
    }

    // ---------------------------------------------------------------------------------------------
    // Mock NFT
    // ---------------------------------------------------------------------------------------------

    function test_nftMintRestrictedToMinter() public {
        vm.expectRevert(MockAavegotchi.NotMinter.selector);
        nft.mint(seller);
        vm.prank(minter);
        uint256 id = nft.mint(seller);
        assertEq(id, 1);
        assertEq(nft.ownerOf(1), seller);
        vm.prank(minter);
        uint256 first = nft.mintBatch(seller, 3);
        assertEq(first, 2);
        assertEq(nft.ownerOf(4), seller);
        assertEq(nft.nextTokenId(), 5);
        vm.prank(minter);
        vm.expectRevert(MockAavegotchi.ZeroCount.selector);
        nft.mintBatch(seller, 0);
    }

    // ---------------------------------------------------------------------------------------------
    // Listing
    // ---------------------------------------------------------------------------------------------

    function test_listEscrowsTheNftAndEmits() public {
        vm.prank(minter);
        uint256 id = nft.mint(seller);
        vm.startPrank(seller);
        nft.approve(address(baazaar), id);
        vm.expectEmit(true, false, false, true, address(baazaar));
        emit MockBaazaar.ListingMocked(1, id, 0.5 ether);
        uint256 listingId = baazaar.list(id, 0.5 ether);
        vm.stopPrank();

        assertEq(listingId, 1);
        assertEq(nft.ownerOf(id), address(baazaar));
        assertEq(baazaar.activeCount(), 1);
        assertEq(baazaar.listingCount(), 1);
        MockBaazaar.Listing memory l = baazaar.getListing(1);
        assertEq(l.seller, seller);
        assertEq(l.tokenId, id);
        assertEq(l.price, 0.5 ether);
        assertTrue(l.active);
    }

    function test_listRequiresApprovalAndOwnership() public {
        vm.prank(minter);
        uint256 id = nft.mint(seller);
        vm.prank(seller);
        vm.expectRevert();
        baazaar.list(id, 1 ether);
        vm.prank(buyer);
        vm.expectRevert();
        baazaar.list(id, 1 ether);
        vm.prank(seller);
        vm.expectRevert(MockBaazaar.ZeroPrice.selector);
        baazaar.list(id, 0);
    }

    function test_activeListingsAreCapped() public {
        uint256 cap = baazaar.MAX_ACTIVE_LISTINGS();
        vm.prank(minter);
        uint256 first = nft.mintBatch(seller, cap + 1);
        vm.startPrank(seller);
        nft.setApprovalForAll(address(baazaar), true);
        for (uint256 i = 0; i < cap; i++) {
            baazaar.list(first + i, 1 ether);
        }
        vm.expectRevert(MockBaazaar.TooManyListings.selector);
        baazaar.list(first + cap, 1 ether);
        vm.stopPrank();
    }

    function test_cancelReturnsTheNftOnlyToTheSeller() public {
        (uint256 listingId, uint256 id) = mintAndList(seller, 1 ether);
        vm.prank(buyer);
        vm.expectRevert(MockBaazaar.NotSeller.selector);
        baazaar.cancel(listingId);

        vm.prank(seller);
        vm.expectEmit(true, false, false, true, address(baazaar));
        emit MockBaazaar.ListingCancelled(listingId, id);
        baazaar.cancel(listingId);
        assertEq(nft.ownerOf(id), seller);
        assertEq(baazaar.activeCount(), 0);

        vm.prank(seller);
        vm.expectRevert(abi.encodeWithSelector(MockBaazaar.ListingNotActive.selector, listingId));
        baazaar.cancel(listingId);
        vm.expectRevert(abi.encodeWithSelector(MockBaazaar.UnknownListing.selector, 9));
        baazaar.getListing(9);
    }

    // ---------------------------------------------------------------------------------------------
    // Cheapest selection
    // ---------------------------------------------------------------------------------------------

    function test_cheapestPicksLowestPriceThenOldest() public {
        (bool found,,,,) = baazaar.cheapest();
        assertFalse(found);

        (uint256 l1, uint256 t1) = mintAndList(seller, 3 ether);
        (uint256 l2, uint256 t2) = mintAndList(seller, 1 ether);
        (, uint256 t3) = mintAndList(seller, 1 ether);
        (uint256 l4,) = mintAndList(seller, 2 ether);

        uint256 listingId;
        uint256 tokenId;
        uint256 price;
        address s;
        (found, listingId, tokenId, price, s) = baazaar.cheapest();
        assertTrue(found);
        assertEq(listingId, l2, "oldest of the two 1 ETH listings");
        assertEq(tokenId, t2);
        assertEq(price, 1 ether);
        assertEq(s, seller);

        vm.prank(seller);
        baazaar.cancel(l2);
        (, listingId, tokenId,,) = baazaar.cheapest();
        assertEq(tokenId, t3, "next 1 ETH listing");

        vm.prank(buyer);
        baazaar.buyCheapest{value: 1 ether}(buyer, 1 ether);
        (, listingId, tokenId, price,) = baazaar.cheapest();
        assertEq(listingId, l4);
        assertEq(price, 2 ether);

        vm.prank(buyer);
        baazaar.buyCheapest{value: 2 ether}(buyer, 2 ether);
        (, listingId, tokenId, price,) = baazaar.cheapest();
        assertEq(listingId, l1);
        assertEq(tokenId, t1);
        assertEq(price, 3 ether);
    }

    // ---------------------------------------------------------------------------------------------
    // Buying with msg.value
    // ---------------------------------------------------------------------------------------------

    function test_buyCheapestWithValuePaysSellerTransfersNftAndRefunds() public {
        (uint256 listingId, uint256 id) = mintAndList(seller, 1 ether);
        uint256 buyerBefore = buyer.balance;

        vm.prank(buyer);
        vm.expectEmit(true, true, false, true, address(baazaar));
        emit MockBaazaar.Sold(listingId, id, 1 ether, seller, buyer, buyer);
        (uint256 boughtListing, uint256 boughtToken, uint256 price) =
            baazaar.buyCheapest{value: 1.5 ether}(buyer, 1 ether);

        assertEq(boughtListing, listingId);
        assertEq(boughtToken, id);
        assertEq(price, 1 ether);
        assertEq(nft.ownerOf(id), buyer, "NFT transferred");
        assertEq(buyer.balance, buyerBefore - 1 ether, "excess refunded");
        assertEq(baazaar.proceeds(seller), 1 ether, "seller credited");
        assertEq(address(baazaar).balance, 1 ether);
        assertEq(baazaar.activeCount(), 0);
        assertFalse(baazaar.getListing(listingId).active);
    }

    function test_buyCheapestRevertsOnUnderpaymentPriceCapAndEmptyMarket() public {
        vm.prank(buyer);
        vm.expectRevert(MockBaazaar.NoListings.selector);
        baazaar.buyCheapest{value: 1 ether}(buyer, 1 ether);

        (, uint256 id) = mintAndList(seller, 1 ether);
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(MockBaazaar.PriceAboveMax.selector, 1 ether, 0.5 ether));
        baazaar.buyCheapest{value: 1 ether}(buyer, 0.5 ether);
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(MockBaazaar.InsufficientPayment.selector, 1 ether, 0.9 ether));
        baazaar.buyCheapest{value: 0.9 ether}(buyer, 1 ether);
        vm.prank(buyer);
        vm.expectRevert(MockBaazaar.ZeroAddress.selector);
        baazaar.buyCheapest{value: 1 ether}(address(0), 1 ether);
        assertEq(nft.ownerOf(id), address(baazaar), "still listed");
        assertEq(baazaar.activeCount(), 1);
    }

    // ---------------------------------------------------------------------------------------------
    // Buying through the payment callback
    // ---------------------------------------------------------------------------------------------

    function test_buyCheapestWithCallbackPaysExactly() public {
        (uint256 listingId, uint256 id) = mintAndList(seller, 1 ether);
        CallbackBuyer cb = new CallbackBuyer(baazaar);
        vm.deal(address(cb), 5 ether);
        (uint256 boughtListing, uint256 boughtToken, uint256 price) = cb.buy(buyer, 1 ether);
        assertEq(boughtListing, listingId);
        assertEq(boughtToken, id);
        assertEq(price, 1 ether);
        assertEq(cb.lastListingId(), listingId);
        assertEq(cb.lastAmount(), 1 ether);
        assertEq(address(cb).balance, 4 ether);
        assertEq(nft.ownerOf(id), buyer);
        assertEq(baazaar.proceeds(seller), 1 ether);
    }

    function test_buyCheapestWithCallbackRevertsWhenUnpaid() public {
        (, uint256 id) = mintAndList(seller, 1 ether);
        StingyBuyer stingy = new StingyBuyer(baazaar);
        vm.expectRevert(MockBaazaar.Unpaid.selector);
        stingy.buy(buyer, 1 ether);
        assertEq(nft.ownerOf(id), address(baazaar));
        assertEq(baazaar.proceeds(seller), 0);
        assertEq(baazaar.activeCount(), 1);
    }

    function test_eoaCannotUseTheCallbackPath() public {
        mintAndList(seller, 1 ether);
        vm.prank(buyer);
        vm.expectRevert();
        baazaar.buyCheapest(buyer, 1 ether);
    }

    // ---------------------------------------------------------------------------------------------
    // Seller payments are pull-based
    // ---------------------------------------------------------------------------------------------

    function test_withdrawProceeds() public {
        mintAndList(seller, 1 ether);
        mintAndList(seller, 2 ether);
        vm.startPrank(buyer);
        baazaar.buyCheapest{value: 1 ether}(buyer, 1 ether);
        baazaar.buyCheapest{value: 2 ether}(buyer, 2 ether);
        vm.stopPrank();
        assertEq(baazaar.proceeds(seller), 3 ether);

        uint256 before = seller.balance;
        vm.prank(seller);
        vm.expectEmit(true, false, false, true, address(baazaar));
        emit MockBaazaar.ProceedsWithdrawn(seller, 3 ether);
        baazaar.withdrawProceeds();
        assertEq(seller.balance, before + 3 ether);
        assertEq(baazaar.proceeds(seller), 0);
        assertEq(address(baazaar).balance, 0);

        vm.prank(seller);
        vm.expectRevert(MockBaazaar.NothingToWithdraw.selector);
        baazaar.withdrawProceeds();
    }

    function test_sellerThatRejectsEthCannotBlockPurchases() public {
        RevertingReceiver grumpy = new RevertingReceiver();
        (uint256 listingId, uint256 id) = mintAndList(address(grumpy), 1 ether);
        vm.prank(buyer);
        baazaar.buyCheapest{value: 1 ether}(buyer, 1 ether);
        assertEq(nft.ownerOf(id), buyer);
        assertEq(baazaar.proceeds(address(grumpy)), 1 ether, "credited, not pushed");
        assertFalse(baazaar.getListing(listingId).active);
        vm.prank(address(grumpy));
        vm.expectRevert(MockBaazaar.TransferFailed.selector);
        baazaar.withdrawProceeds();
    }

    function test_directSafeTransfersToTheBaazaarAreRefused() public {
        vm.prank(minter);
        uint256 id = nft.mint(seller);
        vm.prank(seller);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721InvalidReceiver.selector, address(baazaar)));
        nft.safeTransferFrom(seller, address(baazaar), id);
    }
}
