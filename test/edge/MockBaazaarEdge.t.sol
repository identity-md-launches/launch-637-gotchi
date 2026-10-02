// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {GotchiFixture} from "../utils/GotchiFixture.sol";
import {RevertingReceiver} from "../utils/Mocks.sol";
import {MockBaazaar} from "../../src/MockBaazaar.sol";

/// @notice An NFT recipient that tries to use the marketplace again from inside the delivery callback.
contract ReentrantRecipient is IERC721Receiver {
    MockBaazaar public immutable BAAZAAR;
    uint256 public tokenToList;
    bool public buyReverted;
    bool public cancelReverted;
    bool public withdrawReverted;
    bool public listReverted;
    uint256 public deliveries;

    constructor(MockBaazaar baazaar) {
        BAAZAAR = baazaar;
    }

    receive() external payable {}

    function setTokenToList(uint256 tokenId) external {
        tokenToList = tokenId;
    }

    function onERC721Received(address, address, uint256, bytes calldata) external override returns (bytes4) {
        deliveries += 1;
        try BAAZAAR.buyCheapest{value: address(this).balance}(address(this), type(uint256).max) {
            buyReverted = false;
        } catch {
            buyReverted = true;
        }
        try BAAZAAR.cancel(1) {
            cancelReverted = false;
        } catch {
            cancelReverted = true;
        }
        try BAAZAAR.withdrawProceeds() {
            withdrawReverted = false;
        } catch {
            withdrawReverted = true;
        }
        try BAAZAAR.list(tokenToList, 1) {
            listReverted = false;
        } catch {
            listReverted = true;
        }
        return IERC721Receiver.onERC721Received.selector;
    }
}

/// @notice Marketplace edges: reentrancy through the NFT callback, recipients that cannot take NFTs,
/// ownership versus approval, relisting, price ordering and payment exactness.
/// forge-config: default.fuzz.runs = 512
contract MockBaazaarEdgeTest is GotchiFixture {
    address buyer = makeAddr("buyer");

    function setUp() public override {
        super.setUp();
        vm.deal(buyer, 100 ether);
    }

    function test_recipientCannotReenterTheMarketFromTheDeliveryCallback() public {
        (uint256 firstListing, uint256 firstId) = mintAndList(seller, 1 ether);
        (, uint256 secondId) = mintAndList(seller, 2 ether);
        ReentrantRecipient recipient = new ReentrantRecipient(baazaar);
        vm.deal(address(recipient), 5 ether);
        // Give the recipient a gotchi of its own so its inner `list` is otherwise legitimate.
        vm.prank(minter);
        uint256 ownId = nft.mint(address(recipient));
        vm.prank(address(recipient));
        nft.setApprovalForAll(address(baazaar), true);
        recipient.setTokenToList(ownId);

        vm.prank(buyer);
        baazaar.buyCheapest{value: 1 ether}(address(recipient), 1 ether);

        assertEq(recipient.deliveries(), 1);
        assertTrue(recipient.buyReverted(), "nested buyCheapest must revert");
        assertTrue(recipient.cancelReverted(), "nested cancel must revert");
        assertTrue(recipient.withdrawReverted(), "nested withdrawProceeds must revert");
        assertTrue(recipient.listReverted(), "nested list must revert");
        assertEq(nft.ownerOf(firstId), address(recipient), "the outer purchase completed");
        assertEq(nft.ownerOf(secondId), address(baazaar), "the dearer listing was not touched");
        assertEq(nft.ownerOf(ownId), address(recipient), "the nested listing did not happen");
        assertEq(baazaar.activeCount(), 1);
        assertEq(baazaar.listingCount(), 2);
        assertFalse(baazaar.getListing(firstListing).active);
        assertEq(address(recipient).balance, 5 ether, "the recipient's ETH never moved");
        assertEq(address(baazaar).balance, 1 ether);
        assertEq(baazaar.proceeds(seller), 1 ether);
    }

    function test_recipientThatCannotReceiveNftsRevertsAndLeavesTheListingIntact() public {
        (uint256 listingId, uint256 id) = mintAndList(seller, 1 ether);
        address noReceiver = address(new RevertingReceiver());
        uint256 buyerBefore = buyer.balance;
        vm.prank(buyer);
        vm.expectRevert();
        baazaar.buyCheapest{value: 1 ether}(noReceiver, 1 ether);
        assertTrue(baazaar.getListing(listingId).active, "listing still active");
        assertEq(nft.ownerOf(id), address(baazaar));
        assertEq(baazaar.proceeds(seller), 0, "seller not credited for a failed sale");
        assertEq(buyer.balance, buyerBefore, "buyer kept their ETH");
        assertEq(baazaar.activeCount(), 1);
    }

    function test_maxPriceEqualToThePriceIsAccepted() public {
        (, uint256 id) = mintAndList(seller, 1 ether);
        vm.prank(buyer);
        baazaar.buyCheapest{value: 1 ether}(buyer, 1 ether);
        assertEq(nft.ownerOf(id), buyer);
    }

    function test_maxPriceOfZeroNeverBuys() public {
        mintAndList(seller, 1);
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(MockBaazaar.PriceAboveMax.selector, 1, 0));
        baazaar.buyCheapest{value: 1}(buyer, 0);
    }

    function test_anApprovedOperatorCannotListSomebodyElsesToken() public {
        vm.prank(minter);
        uint256 id = nft.mint(seller);
        address operatorOfSeller = makeAddr("operatorOfSeller");
        vm.prank(seller);
        nft.setApprovalForAll(operatorOfSeller, true);
        vm.prank(operatorOfSeller);
        nft.approve(address(baazaar), id);
        // The Baazaar pulls from msg.sender, who is not the owner.
        vm.prank(operatorOfSeller);
        vm.expectRevert();
        baazaar.list(id, 1 ether);
        assertEq(nft.ownerOf(id), seller);
        assertEq(baazaar.listingCount(), 0);
    }

    function test_aListedTokenCannotBeListedAgainUntilCancelled() public {
        (uint256 listingId, uint256 id) = mintAndList(seller, 1 ether);
        vm.prank(seller);
        vm.expectRevert();
        baazaar.list(id, 2 ether);
        assertEq(baazaar.listingCount(), 1);

        vm.prank(seller);
        baazaar.cancel(listingId);
        vm.startPrank(seller);
        nft.approve(address(baazaar), id);
        uint256 relisted = baazaar.list(id, 2 ether);
        vm.stopPrank();
        assertEq(relisted, 2, "a relisting gets a fresh id");
        assertEq(baazaar.getListing(relisted).price, 2 ether);
        assertFalse(baazaar.getListing(listingId).active);
        assertEq(baazaar.activeCount(), 1);
    }

    function test_cancelAfterASaleIsRefused() public {
        (uint256 listingId, uint256 id) = mintAndList(seller, 1 ether);
        vm.prank(buyer);
        baazaar.buyCheapest{value: 1 ether}(buyer, 1 ether);
        vm.prank(seller);
        vm.expectRevert(abi.encodeWithSelector(MockBaazaar.ListingNotActive.selector, listingId));
        baazaar.cancel(listingId);
        assertEq(nft.ownerOf(id), buyer);
    }

    function test_theActiveCapFreesWhenListingsCloseByPurchaseOrCancel() public {
        uint256 cap = baazaar.MAX_ACTIVE_LISTINGS();
        vm.prank(minter);
        uint256 first = nft.mintBatch(seller, cap + 2);
        vm.startPrank(seller);
        nft.setApprovalForAll(address(baazaar), true);
        for (uint256 i = 0; i < cap; i++) {
            baazaar.list(first + i, 1 ether + i);
        }
        vm.expectRevert(MockBaazaar.TooManyListings.selector);
        baazaar.list(first + cap, 1 ether);
        baazaar.cancel(5);
        uint256 afterCancel = baazaar.list(first + cap, 1 ether);
        vm.stopPrank();
        assertEq(afterCancel, cap + 1);
        assertEq(baazaar.activeCount(), cap);

        vm.prank(buyer);
        baazaar.buyCheapest{value: 1 ether}(buyer, 1 ether);
        assertEq(baazaar.activeCount(), cap - 1);
        vm.startPrank(seller);
        baazaar.list(first + cap + 1, 1 ether);
        vm.stopPrank();
        assertEq(baazaar.activeCount(), cap);
    }

    function test_purchasesDrainTheMarketInPriceThenAgeOrder() public {
        (, uint256 t1) = mintAndList(seller, 3 ether);
        (, uint256 t2) = mintAndList(seller, 1 ether);
        (, uint256 t3) = mintAndList(seller, 2 ether);
        (, uint256 t4) = mintAndList(seller, 1 ether);
        uint256[4] memory expected = [t2, t4, t3, t1];
        uint256[4] memory prices = [uint256(1 ether), 1 ether, 2 ether, 3 ether];
        for (uint256 i = 0; i < 4; i++) {
            vm.prank(buyer);
            (, uint256 tokenId, uint256 price) = baazaar.buyCheapest{value: 3 ether}(buyer, 3 ether);
            assertEq(tokenId, expected[i], "order");
            assertEq(price, prices[i], "price");
        }
        (bool found,,,,) = baazaar.cheapest();
        assertFalse(found);
        assertEq(baazaar.proceeds(seller), 7 ether);
        assertEq(buyer.balance, 100 ether - 7 ether, "only the prices were charged");
    }

    function testFuzz_buyerPaysExactlyThePriceAndTheSellerIsCreditedIt(uint256 price, uint256 extra) public {
        price = bound(price, 1, 10 ether);
        extra = bound(extra, 0, 10 ether);
        (, uint256 id) = mintAndList(seller, price);
        uint256 before = buyer.balance;
        vm.prank(buyer);
        (,, uint256 paid) = baazaar.buyCheapest{value: price + extra}(buyer, price);
        assertEq(paid, price);
        assertEq(buyer.balance, before - price, "excess refunded");
        assertEq(baazaar.proceeds(seller), price);
        assertEq(address(baazaar).balance, price);
        assertEq(nft.ownerOf(id), buyer);
        uint256 sellerBefore = seller.balance;
        vm.prank(seller);
        baazaar.withdrawProceeds();
        assertEq(seller.balance, sellerBefore + price);
        assertEq(address(baazaar).balance, 0, "nothing stays behind");
    }

    function testFuzz_underpaymentByOneWeiIsRefused(uint256 price) public {
        price = bound(price, 2, 10 ether);
        mintAndList(seller, price);
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(MockBaazaar.InsufficientPayment.selector, price, price - 1));
        baazaar.buyCheapest{value: price - 1}(buyer, price);
        assertEq(baazaar.activeCount(), 1);
    }

    function test_getListingRejectsTheSentinelAndOutOfRangeIds() public {
        mintAndList(seller, 1 ether);
        vm.expectRevert(abi.encodeWithSelector(MockBaazaar.UnknownListing.selector, 0));
        baazaar.getListing(0);
        vm.expectRevert(abi.encodeWithSelector(MockBaazaar.UnknownListing.selector, 2));
        baazaar.getListing(2);
        vm.prank(seller);
        vm.expectRevert(abi.encodeWithSelector(MockBaazaar.UnknownListing.selector, 0));
        baazaar.cancel(0);
    }
}
