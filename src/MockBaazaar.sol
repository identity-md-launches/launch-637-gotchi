// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @notice A contract buyer that pays for a listing when the Baazaar asks it to.
/// @dev `buyCheapest` called with `msg.value == 0` pays through this callback instead: the Baazaar
/// calls `payForListing(listingId, price)` on `msg.sender` and then checks its own balance grew by
/// `price`. The FeeSink buys this way so that its ETH only ever leaves through a call the Baazaar
/// itself initiated.
interface IBaazaarBuyer {
    function payForListing(uint256 listingId, uint256 amount) external;
}

/// @title MockBaazaar
/// @notice Minimal ETH-priced marketplace for `MockAavegotchi` tokens: list, cancel, buy the cheapest.
/// Stands in for the Aavegotchi Baazaar on Sepolia; the real Baazaar is a README TODO.
///
/// @dev Listings escrow the NFT in this contract. Sellers are paid with pull payments (`proceeds`,
/// `withdrawProceeds`) so a seller that cannot receive ETH can never block a purchase. The number of
/// simultaneously active listings is capped so that `cheapest()` stays affordable to scan.
/// There is no admin role: sellers manage their own listings, nobody can delist or reprice others'.
contract MockBaazaar is ReentrancyGuard {
    struct Listing {
        address seller;
        uint256 tokenId;
        uint256 price;
        bool active;
    }

    /// @notice Maximum number of active listings at any time (bounds the `cheapest()` scan).
    uint256 public constant MAX_ACTIVE_LISTINGS = 128;

    /// @notice The NFT collection sold here.
    IERC721 public immutable NFT;

    /// @notice Number of listings that are currently active.
    uint256 public activeCount;

    /// @notice ETH owed to sellers, claimable with `withdrawProceeds`.
    mapping(address seller => uint256 amount) public proceeds;

    // Index 0 is a sentinel so that listing id 0 means "none".
    Listing[] private _listings;

    /// @notice A listing was created. Kept for the UI: indexed listing id, token and price.
    event ListingMocked(uint256 indexed listingId, uint256 tokenId, uint256 price);
    /// @notice A seller cancelled a listing and got the NFT back.
    event ListingCancelled(uint256 indexed listingId, uint256 tokenId);
    /// @notice A listing was bought.
    event Sold(
        uint256 indexed listingId,
        uint256 tokenId,
        uint256 price,
        address indexed seller,
        address buyer,
        address recipient
    );
    /// @notice A seller withdrew their proceeds.
    event ProceedsWithdrawn(address indexed seller, uint256 amount);

    error ZeroAddress();
    error ZeroPrice();
    error TooManyListings();
    error UnknownListing(uint256 listingId);
    error ListingNotActive(uint256 listingId);
    error NotSeller();
    error NoListings();
    error PriceAboveMax(uint256 price, uint256 maxPrice);
    error InsufficientPayment(uint256 price, uint256 paid);
    error Unpaid();
    error RefundFailed();
    error NothingToWithdraw();
    error TransferFailed();

    constructor(address nft) {
        if (nft == address(0)) revert ZeroAddress();
        NFT = IERC721(nft);
        _listings.push();
    }

    /// @notice Accepts the ETH an `IBaazaarBuyer` sends from `payForListing`.
    receive() external payable {}

    // ---------------------------------------------------------------------------------------------
    // Sellers
    // ---------------------------------------------------------------------------------------------

    /// @notice Lists `tokenId` for `price` wei. The caller must own it and have approved this contract.
    function list(uint256 tokenId, uint256 price) external nonReentrant returns (uint256 listingId) {
        if (price < 1) revert ZeroPrice();
        if (activeCount >= MAX_ACTIVE_LISTINGS) revert TooManyListings();
        listingId = _listings.length;
        _listings.push(Listing({seller: msg.sender, tokenId: tokenId, price: price, active: true}));
        activeCount += 1;
        emit ListingMocked(listingId, tokenId, price);
        NFT.transferFrom(msg.sender, address(this), tokenId);
    }

    /// @notice Cancels an active listing; only its seller may do so.
    function cancel(uint256 listingId) external nonReentrant {
        Listing storage listing = _get(listingId);
        if (listing.seller != msg.sender) revert NotSeller();
        if (!listing.active) revert ListingNotActive(listingId);
        listing.active = false;
        activeCount -= 1;
        emit ListingCancelled(listingId, listing.tokenId);
        NFT.transferFrom(address(this), msg.sender, listing.tokenId);
    }

    /// @notice Sends the caller everything they are owed from sales.
    function withdrawProceeds() external nonReentrant {
        uint256 amount = proceeds[msg.sender];
        if (amount < 1) revert NothingToWithdraw();
        proceeds[msg.sender] = 0;
        emit ProceedsWithdrawn(msg.sender, amount);
        (bool ok,) = msg.sender.call{value: amount}("");
        if (!ok) revert TransferFailed();
    }

    // ---------------------------------------------------------------------------------------------
    // Buyers
    // ---------------------------------------------------------------------------------------------

    /// @notice Buys the cheapest active listing (lowest price; ties go to the oldest listing) and
    /// sends the NFT to `recipient`.
    /// @dev Two ways to pay. With `msg.value > 0` the price is taken from it and the excess refunded.
    /// With `msg.value == 0` the caller must be an `IBaazaarBuyer`: it is called back for exactly the
    /// price, and the purchase reverts unless this contract's balance grew by that much.
    /// @param recipient Who receives the NFT (via `safeTransferFrom`, so a contract must accept it).
    /// @param maxPrice Reverts if the cheapest listing costs more than this.
    function buyCheapest(address recipient, uint256 maxPrice)
        external
        payable
        nonReentrant
        returns (uint256 listingId, uint256 tokenId, uint256 price)
    {
        if (recipient == address(0)) revert ZeroAddress();
        bool found = false;
        address seller = address(0);
        (found, listingId, tokenId, price, seller) = cheapest();
        if (!found) revert NoListings();
        if (price > maxPrice) revert PriceAboveMax(price, maxPrice);

        Listing storage listing = _listings[listingId];
        listing.active = false;
        activeCount -= 1;
        proceeds[seller] += price;
        emit Sold(listingId, tokenId, price, seller, msg.sender, recipient);

        if (msg.value > 0) {
            if (msg.value < price) revert InsufficientPayment(price, msg.value);
            uint256 refund = msg.value - price;
            NFT.safeTransferFrom(address(this), recipient, tokenId);
            if (refund > 0) {
                (bool ok,) = msg.sender.call{value: refund}("");
                if (!ok) revert RefundFailed();
            }
        } else {
            uint256 balanceBefore = address(this).balance;
            IBaazaarBuyer(msg.sender).payForListing(listingId, price);
            if (address(this).balance < balanceBefore + price) revert Unpaid();
            NFT.safeTransferFrom(address(this), recipient, tokenId);
        }
    }

    // ---------------------------------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------------------------------

    /// @notice The cheapest active listing, if any (ties resolved towards the lowest listing id).
    function cheapest()
        public
        view
        returns (bool found, uint256 listingId, uint256 tokenId, uint256 price, address seller)
    {
        uint256 length = _listings.length;
        for (uint256 i = 1; i < length; i++) {
            Listing storage listing = _listings[i];
            if (!listing.active) continue;
            if (!found || listing.price < price) {
                found = true;
                listingId = i;
                tokenId = listing.tokenId;
                price = listing.price;
                seller = listing.seller;
            }
        }
    }

    /// @notice Number of listings ever created (active or not). Ids run from 1 to this value.
    function listingCount() external view returns (uint256) {
        return _listings.length - 1;
    }

    /// @notice A listing by id.
    function getListing(uint256 listingId) external view returns (Listing memory) {
        return _get(listingId);
    }

    function _get(uint256 listingId) private view returns (Listing storage) {
        if (listingId < 1 || listingId >= _listings.length) revert UnknownListing(listingId);
        return _listings[listingId];
    }
}
