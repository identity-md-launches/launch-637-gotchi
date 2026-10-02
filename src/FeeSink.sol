// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {GotchiFeeHook} from "./GotchiFeeHook.sol";
import {MockBaazaar, IBaazaarBuyer} from "./MockBaazaar.sol";
import {FlipEscrow} from "./FlipEscrow.sol";

/// @title FeeSink
/// @notice Receives the ETH the hook skims and, once it holds at least `MIN_BUY_THRESHOLD`, buys the
/// cheapest listed mock gotchi from the Baazaar with the FlipEscrow as recipient.
///
/// @dev The purchase is a permissionless crank (`triggerBuy`): anyone (a keeper, the UI, a swapper) may
/// call it whenever the threshold is met and an affordable listing exists. It is not run inside the
/// swap so that swaps stay cheap and can never be blocked by marketplace state.
///
/// ETH leaves this contract only through `payForListing`, which the Baazaar calls back during a
/// `triggerBuy` for exactly the price `triggerBuy` armed. Reentrancy: `triggerBuy` is `nonReentrant`,
/// `payForListing` disarms before paying, and the Baazaar/NFT/escrow addresses are immutable.
///
/// No admin role: nobody can withdraw, redirect or change the threshold. Donations are accepted and
/// spent the same way as fees.
contract FeeSink is IBaazaarBuyer, ReentrancyGuard {
    /// @notice Balance at or above which `triggerBuy` is allowed.
    uint256 public constant MIN_BUY_THRESHOLD = 0.01 ether;

    /// @notice The hook that feeds this sink (bound in the constructor).
    GotchiFeeHook public immutable HOOK;
    /// @notice Where gotchis are bought.
    MockBaazaar public immutable BAAZAAR;
    /// @notice Receives every bought gotchi.
    FlipEscrow public immutable ESCROW;

    /// @notice Price armed by the current `triggerBuy`; non-zero only while a purchase is in flight.
    uint256 public pendingPayment;
    /// @notice Total ETH ever received (fees and donations).
    uint256 public totalCollected;
    /// @notice Total ETH ever spent on gotchis.
    uint256 public totalSpent;
    /// @notice Number of gotchis bought.
    uint256 public buyCount;

    /// @notice ETH arrived; `pool` is the sender (the PoolManager for hook fees).
    event FeesCollected(address indexed pool, uint256 amountEth);
    /// @notice A purchase of the cheapest listing was triggered.
    event BuyTriggered(uint256 indexed listingId, uint256 priceEth, uint256 tokenId);

    error ZeroAddress();
    error BelowThreshold(uint256 balance, uint256 threshold);
    error NoListing();
    error CannotAfford(uint256 price, uint256 balance);
    error NotBaazaar();
    error UnexpectedPayment(uint256 amount, uint256 expected);
    error PaymentFailed();
    error WrongToken(uint256 expected, uint256 actual);
    error PaymentNotCollected();

    constructor(address hook, address baazaar, address escrow) {
        if (hook == address(0) || baazaar == address(0) || escrow == address(0)) revert ZeroAddress();
        HOOK = GotchiFeeHook(hook);
        BAAZAAR = MockBaazaar(payable(baazaar));
        ESCROW = FlipEscrow(escrow);
        GotchiFeeHook(hook).bindFeeSink();
    }

    /// @notice Accepts fee ETH from the PoolManager (and donations from anyone).
    receive() external payable {
        totalCollected += msg.value;
        emit FeesCollected(msg.sender, msg.value);
    }

    // ---------------------------------------------------------------------------------------------
    // Crank
    // ---------------------------------------------------------------------------------------------

    /// @notice Buys the cheapest listing for the escrow. Reverts below the threshold, without a
    /// listing, or when the cheapest listing costs more than the balance.
    /// @return acquisitionId The escrow's id for the bought gotchi.
    function triggerBuy() external nonReentrant returns (uint256 acquisitionId) {
        uint256 balance = address(this).balance;
        if (balance < MIN_BUY_THRESHOLD) revert BelowThreshold(balance, MIN_BUY_THRESHOLD);
        (bool found, uint256 listingId, uint256 tokenId, uint256 price, address seller) = BAAZAAR.cheapest();
        if (!found || seller == address(0)) revert NoListing();
        if (price > balance) revert CannotAfford(price, balance);

        acquisitionId = ESCROW.acquisitionCount();
        pendingPayment = price;
        totalSpent += price;
        buyCount += 1;
        emit BuyTriggered(listingId, price, tokenId);

        (uint256 boughtListingId, uint256 boughtTokenId, uint256 paid) = BAAZAAR.buyCheapest(address(ESCROW), price);
        if (boughtListingId != listingId || boughtTokenId != tokenId || paid != price) {
            revert WrongToken(tokenId, boughtTokenId);
        }
        if (pendingPayment > 0) revert PaymentNotCollected();
    }

    /// @inheritdoc IBaazaarBuyer
    /// @dev Only the Baazaar, only for the amount armed by the running `triggerBuy`, only once.
    function payForListing(uint256, uint256 amount) external override {
        if (msg.sender != address(BAAZAAR)) revert NotBaazaar();
        uint256 expected = pendingPayment;
        if (amount < 1 || amount != expected) revert UnexpectedPayment(amount, expected);
        pendingPayment = 0;
        (bool ok,) = msg.sender.call{value: amount}("");
        if (!ok) revert PaymentFailed();
    }

    // ---------------------------------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------------------------------

    /// @notice Whether `triggerBuy` would succeed right now (and why not otherwise), with the listing
    /// it would buy.
    function canBuy()
        external
        view
        returns (bool ok, string memory reason, uint256 listingId, uint256 tokenId, uint256 price, address seller)
    {
        uint256 balance = address(this).balance;
        bool found = false;
        (found, listingId, tokenId, price, seller) = BAAZAAR.cheapest();
        if (balance < MIN_BUY_THRESHOLD) {
            reason = "below threshold";
        } else if (!found) {
            reason = "no listing";
        } else if (price > balance) {
            reason = "cannot afford cheapest listing";
        } else {
            ok = true;
        }
    }
}
