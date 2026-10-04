// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {LaunchToken} from "../../src/LaunchToken.sol";
import {GotchiFeeHook} from "../../src/GotchiFeeHook.sol";
import {FeeSink} from "../../src/FeeSink.sol";
import {MockAavegotchi} from "../../src/MockAavegotchi.sol";
import {MockBaazaar} from "../../src/MockBaazaar.sol";
import {FlipEscrow} from "../../src/FlipEscrow.sol";
import {HolderWeightedPicker} from "../../src/HolderWeightedPicker.sol";

/// @notice Drives the ETH/NFT market half of the system (FeeSink, MockBaazaar, FlipEscrow,
/// HolderWeightedPicker, MockAavegotchi) with bounded random calls from several actors. The hook's
/// `take` is stood in for by plain ETH transfers into the sink, which is exactly how the PoolManager
/// delivers fees.
///
/// Expectations that can be checked right after a call are recorded as violations instead of reverting,
/// so a broken expectation can never hide behind the runner's revert tolerance; `invariant_noViolations`
/// surfaces them. Nothing here asserts that `requestFlip` can or cannot succeed: whether it ever does is
/// counted in `ghostRequestFlipSuccesses` and reported separately.
contract MarketHandler is Test {
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;

    LaunchToken public token;
    MockAavegotchi public nft;
    MockBaazaar public baazaar;
    HolderWeightedPicker public picker;
    FlipEscrow public escrow;
    FeeSink public sink;
    address public operator;

    address[] public sellers;
    address[] public holders;
    address[] public buyers;
    uint256[] public tokenIds;
    bytes32[] internal secrets;

    // Ghost accounting.
    uint256 public ghostFunded;
    uint256 public ghostSpent;
    uint256 public ghostBuys;
    uint256 public ghostEscrowDeliveries;
    uint256 public ghostOutstandingProceeds;
    uint256 public ghostRequestFlipSuccesses;
    uint256 public ghostResolvedCount;
    uint256 public ghostCapRefusals;
    /// @dev NFTs pushed into the escrow with a plain `transferFrom` and not yet swept.
    uint256 public ghostStraysInEscrow;
    uint256 public ghostStraysSwept;
    uint256 public ghostDeposited;
    uint256 public ghostWithdrawn;
    mapping(uint256 acquisitionId => bool) public ghostResolved;
    mapping(uint256 acquisitionId => bool) public ghostBurned;
    mapping(uint256 acquisitionId => address) public ghostRecipient;
    mapping(uint256 tokenId => bool) public ghostIsStrayInEscrow;

    string[] public violations;
    mapping(bytes32 selector => uint256) public calls;

    receive() external payable {}

    constructor(
        LaunchToken token_,
        MockAavegotchi nft_,
        MockBaazaar baazaar_,
        HolderWeightedPicker picker_,
        FlipEscrow escrow_,
        FeeSink sink_,
        address operator_
    ) {
        token = token_;
        nft = nft_;
        baazaar = baazaar_;
        picker = picker_;
        escrow = escrow_;
        sink = sink_;
        operator = operator_;
        for (uint256 i = 0; i < 3; i++) {
            sellers.push(makeAddr(string.concat("seller", vm.toString(i))));
            buyers.push(makeAddr(string.concat("buyer", vm.toString(i))));
        }
        for (uint256 i = 0; i < 4; i++) {
            holders.push(makeAddr(string.concat("holder", vm.toString(i))));
        }
    }

    // ---------------------------------------------------------------------------------------------
    // Views for the invariants
    // ---------------------------------------------------------------------------------------------

    function tokenCount() external view returns (uint256) {
        return tokenIds.length;
    }

    function sellerCount() external view returns (uint256) {
        return sellers.length;
    }

    function holderCount() external view returns (uint256) {
        return holders.length;
    }

    function violationCount() external view returns (uint256) {
        return violations.length;
    }

    // ---------------------------------------------------------------------------------------------
    // Fee flow into the sink
    // ---------------------------------------------------------------------------------------------

    /// @dev Stands in for `PoolManager.take(ETH, sink, fee)`.
    function fund(uint256 amount) external count("fund") {
        amount = bound(amount, 0.005 ether, 0.1 ether);
        vm.deal(address(this), amount);
        uint256 before = sink.totalCollected();
        (bool ok,) = address(sink).call{value: amount}("");
        _check(ok, "sink refused ETH");
        _check(sink.totalCollected() == before + amount, "totalCollected did not grow by the amount sent");
        ghostFunded += amount;
    }

    /// @dev ETH nobody could ever claim must be refused outright, so the Baazaar's balance stays exactly
    /// what sellers are owed.
    function strayEthToBaazaar(uint256 amount) external count("strayEthToBaazaar") {
        amount = bound(amount, 1, 0.001 ether);
        vm.deal(address(this), amount);
        uint256 before = address(baazaar).balance;
        (bool ok,) = address(baazaar).call{value: amount}("");
        _check(!ok, "baazaar accepted stray ETH outside a purchase callback");
        _check(address(baazaar).balance == before, "refused ETH still changed the balance");
    }

    // ---------------------------------------------------------------------------------------------
    // Marketplace
    // ---------------------------------------------------------------------------------------------

    function list(uint256 sellerSeed, uint256 price) external count("list") {
        address s = sellers[sellerSeed % sellers.length];
        price = bound(price, 1, 0.02 ether);
        uint256 id = nft.mint(s);
        tokenIds.push(id);
        bool full = baazaar.activeCount() >= baazaar.MAX_ACTIVE_LISTINGS();
        vm.startPrank(s);
        nft.approve(address(baazaar), id);
        try baazaar.list(id, price) returns (uint256 listingId) {
            _check(!full, "listed past the active cap");
            MockBaazaar.Listing memory l = baazaar.getListing(listingId);
            _check(l.seller == s && l.tokenId == id && l.price == price && l.active, "listing stored wrong");
            _check(nft.ownerOf(id) == address(baazaar), "listed NFT not escrowed");
        } catch {
            _check(full, "list reverted below the cap");
            _check(nft.ownerOf(id) == s, "failed listing moved the NFT");
        }
        vm.stopPrank();
    }

    /// @dev A listing priced above the sink's cap: the crank must leave it alone however rich the sink is.
    function listAboveCap(uint256 sellerSeed, uint256 price) external count("listAboveCap") {
        address s = sellers[sellerSeed % sellers.length];
        price = bound(price, sink.MAX_BUY_PRICE() + 1, 1 ether);
        if (baazaar.activeCount() >= baazaar.MAX_ACTIVE_LISTINGS()) return;
        uint256 id = nft.mint(s);
        tokenIds.push(id);
        vm.startPrank(s);
        nft.approve(address(baazaar), id);
        baazaar.list(id, price);
        vm.stopPrank();
    }

    function cancel(uint256 listingSeed) external count("cancel") {
        uint256 n = baazaar.listingCount();
        if (n == 0) return;
        uint256 id = listingSeed % n + 1;
        MockBaazaar.Listing memory l = baazaar.getListing(id);
        vm.prank(l.seller);
        try baazaar.cancel(id) {
            _check(l.active, "cancelled an inactive listing");
            _check(nft.ownerOf(l.tokenId) == l.seller, "cancel did not return the NFT");
            _check(!baazaar.getListing(id).active, "cancelled listing still active");
        } catch {
            _check(!l.active, "cancel of an active listing by its seller reverted");
        }
    }

    function cancelByStranger(uint256 listingSeed, uint256 buyerSeed) external count("cancelByStranger") {
        uint256 n = baazaar.listingCount();
        if (n == 0) return;
        uint256 id = listingSeed % n + 1;
        address who = buyers[buyerSeed % buyers.length];
        vm.prank(who);
        try baazaar.cancel(id) {
            _check(false, "a non-seller cancelled a listing");
        } catch {}
    }

    function buyWithEth(uint256 buyerSeed, uint256 extra, bool toEscrow) external count("buyWithEth") {
        (bool found,, uint256 tokenId, uint256 price, address s) = baazaar.cheapest();
        if (!found) return;
        address b = buyers[buyerSeed % buyers.length];
        extra = bound(extra, 0, 0.01 ether);
        vm.deal(b, price + extra);
        address recipient = toEscrow ? address(escrow) : b;
        uint256 acquisitionsBefore = escrow.acquisitionCount();
        uint256 owedBefore = baazaar.proceeds(s);
        vm.prank(b);
        baazaar.buyCheapest{value: price + extra}(recipient, price);
        _check(b.balance == extra, "excess ETH not refunded to the buyer");
        _check(nft.ownerOf(tokenId) == recipient, "bought NFT not with the recipient");
        _check(baazaar.proceeds(s) == owedBefore + price, "seller not credited the price");
        ghostOutstandingProceeds += price;
        if (toEscrow) {
            _check(escrow.acquisitionCount() == acquisitionsBefore + 1, "escrow did not register the delivery");
            ghostEscrowDeliveries += 1;
        } else {
            _check(escrow.acquisitionCount() == acquisitionsBefore, "escrow registered somebody else's purchase");
        }
    }

    function withdrawProceeds(uint256 sellerSeed) external count("withdrawProceeds") {
        address s = sellers[sellerSeed % sellers.length];
        uint256 owed = baazaar.proceeds(s);
        uint256 balanceBefore = s.balance;
        vm.prank(s);
        if (owed == 0) {
            try baazaar.withdrawProceeds() {
                _check(false, "withdrew with nothing owed");
            } catch {}
            return;
        }
        baazaar.withdrawProceeds();
        _check(s.balance == balanceBefore + owed, "seller did not receive what was owed");
        _check(baazaar.proceeds(s) == 0, "proceeds not cleared");
        ghostOutstandingProceeds -= owed;
    }

    // ---------------------------------------------------------------------------------------------
    // The crank
    // ---------------------------------------------------------------------------------------------

    function triggerBuy() external count("triggerBuy") {
        (bool ok, string memory reason,, uint256 tokenId, uint256 price, address s) = sink.canBuy();
        uint256 balanceBefore = address(sink).balance;
        uint256 acquisitionsBefore = escrow.acquisitionCount();
        uint256 owedBefore = s == address(0) ? 0 : baazaar.proceeds(s);
        // The handler's own reading of the rules, independent of `canBuy`.
        (bool listed,,, uint256 cheapestPrice,) = baazaar.cheapest();
        bool expectOk = balanceBefore >= sink.MIN_BUY_THRESHOLD() && listed && cheapestPrice <= balanceBefore
            && cheapestPrice <= sink.MAX_BUY_PRICE();
        _check(ok == expectOk, "canBuy disagrees with the threshold, affordability and cap rules");
        if (!ok && keccak256(bytes(reason)) == keccak256("cheapest listing above price cap")) ghostCapRefusals += 1;
        try sink.triggerBuy() returns (uint256 acquisitionId) {
            _check(ok, "triggerBuy succeeded although canBuy said no");
            _check(price <= sink.MAX_BUY_PRICE(), "the crank paid more than the cap");
            _check(acquisitionId == acquisitionsBefore, "acquisition id is not the next one");
            _check(escrow.acquisitionCount() == acquisitionsBefore + 1, "escrow did not register the buy");
            _check(address(sink).balance == balanceBefore - price, "sink did not pay exactly the price");
            _check(nft.ownerOf(tokenId) == address(escrow), "bought gotchi is not in the escrow");
            _check(escrow.getAcquisition(acquisitionId).tokenId == tokenId, "acquisition holds another token");
            _check(baazaar.proceeds(s) == owedBefore + price, "seller not credited by the crank");
            _check(sink.pendingPayment() == 0, "payment left armed");
            ghostSpent += price;
            ghostBuys += 1;
            ghostOutstandingProceeds += price;
        } catch {
            _check(!ok, "triggerBuy reverted although canBuy said yes");
            _check(address(sink).balance == balanceBefore, "a failed crank moved ETH");
            _check(sink.pendingPayment() == 0, "a failed crank left a payment armed");
        }
    }

    function payForListingDirectly(uint256 amount, bool asBaazaar) external count("payForListingDirectly") {
        uint256 balanceBefore = address(sink).balance;
        if (asBaazaar) vm.prank(address(baazaar));
        try sink.payForListing(1, bound(amount, 0, 1 ether)) {
            _check(false, "payForListing succeeded outside a crank");
        } catch {}
        _check(address(sink).balance == balanceBefore, "payForListing outside a crank moved ETH");
    }

    // ---------------------------------------------------------------------------------------------
    // Randomness and resolution
    // ---------------------------------------------------------------------------------------------

    function commit(uint256 seed) external count("commit") {
        bytes32 secret = keccak256(abi.encode("gotchi-market-invariant", seed, secrets.length));
        secrets.push(secret);
        uint256 before = escrow.commitmentCount();
        vm.prank(operator);
        escrow.commit(keccak256(abi.encodePacked(secret)));
        _check(escrow.commitmentCount() == before + 1, "commit did not append");
    }

    function commitAsStranger(uint256 seed) external count("commitAsStranger") {
        vm.prank(buyers[seed % buyers.length]);
        try escrow.commit(bytes32(seed | 1)) {
            _check(false, "a non-operator committed");
        } catch {}
    }

    function rollBlocks(uint256 n) external count("rollBlocks") {
        vm.roll(block.number + bound(n, 1, 100));
    }

    function jumpPastDeadlines() external count("jumpPastDeadlines") {
        vm.roll(block.number + escrow.REVEAL_WINDOW_BLOCKS() + 1);
    }

    /// @dev Binds iff the acquisition is pending and the oldest unbound commitment was made in an earlier
    /// block; a commitment from this very block must wait.
    function requestFlip(uint256 acquisitionSeed) external count("requestFlip") {
        uint256 n = escrow.acquisitionCount();
        if (n == 0) return;
        uint256 id = acquisitionSeed % n;
        FlipEscrow.Status status = escrow.getAcquisition(id).status;
        uint256 next = escrow.nextCommitment();
        bool expectOk = status == FlipEscrow.Status.Pending && next < escrow.commitmentCount()
            && escrow.getCommitment(next).commitBlock < block.number;
        try escrow.requestFlip(id) {
            _check(expectOk, "requestFlip succeeded without a pending acquisition and an older commitment");
            FlipEscrow.Acquisition memory a = escrow.getAcquisition(id);
            _check(a.status == FlipEscrow.Status.Requested, "requestFlip did not bind");
            _check(a.commitmentIndex == next, "requestFlip skipped the oldest commitment");
            _check(a.requestBlock == block.number, "request block is not this block");
            _check(a.pickerSnapshotBlock == block.number - 1, "the flip did not freeze the block before the request");
            _check(escrow.nextCommitment() == next + 1, "nextCommitment did not advance by one");
            ghostRequestFlipSuccesses += 1;
        } catch {
            _check(!expectOk, "requestFlip reverted although a pending acquisition and an older commitment exist");
            _check(escrow.nextCommitment() == next, "a failed requestFlip consumed a commitment");
        }
    }

    function reveal(uint256 acquisitionSeed) external count("reveal") {
        uint256 n = escrow.acquisitionCount();
        if (n == 0) return;
        uint256 id = acquisitionSeed % n;
        FlipEscrow.Acquisition memory a = escrow.getAcquisition(id);
        if (a.status != FlipEscrow.Status.Requested) {
            try escrow.reveal(id, bytes32(uint256(1))) {
                _check(false, "reveal succeeded outside Requested");
            } catch {}
            return;
        }
        bytes32 secret = secrets[a.commitmentIndex];
        bool windowOpen = block.number <= a.requestBlock + escrow.REVEAL_WINDOW_BLOCKS();
        uint256 roll = escrow.rollFor(secret, a.requestId);
        bool expectBurn = escrow.isBurnRoll(roll);
        address expectRecipient = DEAD;
        _check(a.pickerSnapshotBlock + 1 == a.requestBlock, "frozen snapshot is not the block before the request");
        if (!expectBurn) {
            // The winner is fixed by the deposits as they stood before the flip was requested, not now.
            (address winner,) = picker.pickAt(a.pickerSnapshotBlock, roll);
            if (winner == address(0)) expectBurn = true;
            else expectRecipient = winner;
        }

        try escrow.reveal(id, keccak256(abi.encode(secret))) {
            _check(false, "a wrong secret resolved a flip");
        } catch {}

        try escrow.reveal(id, secret) {
            _check(windowOpen, "reveal succeeded after the window closed");
            FlipEscrow.Acquisition memory r = escrow.getAcquisition(id);
            _check(r.status == FlipEscrow.Status.Resolved, "revealed acquisition not resolved");
            _check(
                r.burned == expectBurn && r.recipient == expectRecipient, "resolution differs from the roll and picker"
            );
            _check(nft.ownerOf(a.tokenId) == expectRecipient, "NFT did not go to the resolved recipient");
            _record(id, expectBurn, expectRecipient);
        } catch {
            _check(!windowOpen, "reveal with the right secret reverted inside the window");
        }
    }

    function expire(uint256 acquisitionSeed) external count("expire") {
        uint256 n = escrow.acquisitionCount();
        if (n == 0) return;
        uint256 id = acquisitionSeed % n;
        FlipEscrow.Acquisition memory a = escrow.getAcquisition(id);
        bool expirable =
            (a.status == FlipEscrow.Status.Requested && block.number > a.requestBlock + escrow.REVEAL_WINDOW_BLOCKS())
                || (a.status == FlipEscrow.Status.Pending
                    && block.number > a.receivedBlock + escrow.PENDING_TIMEOUT_BLOCKS());
        try escrow.expire(id) {
            _check(expirable, "expire succeeded before its deadline");
            _check(nft.ownerOf(a.tokenId) == DEAD, "expired NFT not burned");
            _check(escrow.getAcquisition(id).burned, "expired acquisition not marked burned");
            _record(id, true, DEAD);
        } catch {
            _check(!expirable, "expire reverted after its deadline");
        }
    }

    // ---------------------------------------------------------------------------------------------
    // Stray NFTs: pushed in without the callback, they are nobody's and can only be burned
    // ---------------------------------------------------------------------------------------------

    function strayNftToEscrow(uint256 sellerSeed) external count("strayNftToEscrow") {
        address s = sellers[sellerSeed % sellers.length];
        uint256 id = nft.mint(s);
        tokenIds.push(id);
        uint256 acquisitionsBefore = escrow.acquisitionCount();
        vm.prank(s);
        nft.transferFrom(s, address(escrow), id);
        _check(escrow.acquisitionCount() == acquisitionsBefore, "a plain transfer created an acquisition");
        (bool found,) = escrow.latestAcquisitionOf(id);
        _check(!found, "a stray token is recorded as acquired");
        ghostIsStrayInEscrow[id] = true;
        ghostStraysInEscrow += 1;
    }

    /// @dev Sweeping succeeds iff the escrow holds the token and no open acquisition covers it; it burns.
    function sweepStray(uint256 tokenSeed) external count("sweepStray") {
        if (tokenIds.length == 0) return;
        uint256 id = tokenIds[tokenSeed % tokenIds.length];
        bool held = nft.ownerOf(id) == address(escrow);
        (bool found, uint256 acquisitionId) = escrow.latestAcquisitionOf(id);
        bool open = found && escrow.getAcquisition(acquisitionId).status != FlipEscrow.Status.Resolved;
        bool expectOk = held && !open;
        try escrow.sweepStray(id) {
            _check(expectOk, "sweepStray moved a token that was not a stray");
            _check(nft.ownerOf(id) == DEAD, "swept token was not burned");
            if (ghostIsStrayInEscrow[id]) {
                ghostIsStrayInEscrow[id] = false;
                ghostStraysInEscrow -= 1;
                ghostStraysSwept += 1;
            } else {
                _check(false, "sweepStray burned a token the handler never pushed in as a stray");
            }
        } catch {
            _check(!expectOk, "sweepStray refused a token the escrow holds with no open acquisition");
            if (held) _check(nft.ownerOf(id) == address(escrow), "a refused sweep moved the token");
        }
    }

    // ---------------------------------------------------------------------------------------------
    // Holder weights
    // ---------------------------------------------------------------------------------------------

    function giveTokens(uint256 holderSeed, uint256 amount) external count("giveTokens") {
        address h = holders[holderSeed % holders.length];
        amount = bound(amount, 1, 1_000_000e18);
        token.transfer(h, amount);
    }

    function moveTokens(uint256 fromSeed, uint256 toSeed, uint256 amount) external count("moveTokens") {
        address from = holders[fromSeed % holders.length];
        address to = holders[toSeed % holders.length];
        uint256 balance = token.balanceOf(from);
        if (balance == 0) return;
        amount = bound(amount, 1, balance);
        vm.prank(from);
        token.transfer(to, amount);
    }

    /// @dev A deposit moves exactly `amount` into the picker's custody and adds it to the holder's weight.
    function deposit(uint256 holderSeed, uint256 amount) external count("deposit") {
        address h = holders[holderSeed % holders.length];
        uint256 balance = token.balanceOf(h);
        amount = bound(amount, 0, balance);
        uint256 weightBefore = picker.weightOf(h);
        uint256 totalBefore = picker.totalWeight();
        vm.startPrank(h);
        token.approve(address(picker), amount);
        try picker.deposit(amount) {
            _check(amount > 0, "a zero deposit succeeded");
            _check(picker.weightOf(h) == weightBefore + amount, "deposit did not add the amount to the weight");
            _check(picker.totalWeight() == totalBefore + amount, "deposit did not add the amount to the total");
            _check(token.balanceOf(h) == balance - amount, "deposit did not take the tokens");
            ghostDeposited += amount;
        } catch {
            _check(amount == 0, "a funded deposit reverted");
        }
        vm.stopPrank();
    }

    /// @dev A holder gets back at most their weight; asking for more (or for nothing) is refused.
    function withdraw(uint256 holderSeed, uint256 amount) external count("withdraw") {
        address h = holders[holderSeed % holders.length];
        uint256 weight = picker.weightOf(h);
        amount = bound(amount, 0, weight + 1);
        bool expectOk = amount > 0 && amount <= weight;
        uint256 balance = token.balanceOf(h);
        uint256 pastTotal = picker.totalWeightAt(block.number - 1);
        vm.prank(h);
        try picker.withdraw(amount) {
            _check(expectOk, "withdraw succeeded for nothing or beyond the holder's weight");
            _check(picker.weightOf(h) == weight - amount, "withdraw did not lower the weight by the amount");
            _check(token.balanceOf(h) == balance + amount, "withdraw did not return the tokens");
            _check(picker.totalWeightAt(block.number - 1) == pastTotal, "withdraw rewrote an earlier block");
            ghostWithdrawn += amount;
        } catch {
            _check(!expectOk, "withdraw of deposited weight reverted");
        }
    }

    // ---------------------------------------------------------------------------------------------
    // Internals
    // ---------------------------------------------------------------------------------------------

    function _record(uint256 id, bool burned, address recipient) private {
        if (!ghostResolved[id]) ghostResolvedCount += 1;
        ghostResolved[id] = true;
        ghostBurned[id] = burned;
        ghostRecipient[id] = recipient;
    }

    function _check(bool condition, string memory what) private {
        if (!condition) violations.push(what);
    }

    modifier count(string memory name) {
        calls[keccak256(bytes(name))] += 1;
        _;
    }
}

/// forge-config: default.invariant.runs = 48
/// forge-config: default.invariant.depth = 120
contract MarketInvariantTest is StdInvariant, Test {
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;

    LaunchToken token;
    MockAavegotchi nft;
    MockBaazaar baazaar;
    HolderWeightedPicker picker;
    FlipEscrow escrow;
    FeeSink sink;
    MarketHandler handler;
    address operator = makeAddr("operator");
    address poolManager = makeAddr("poolManager");

    function setUp() public {
        token = new LaunchToken();
        GotchiFeeHook hook = new GotchiFeeHook(poolManager);
        // The handler mints the mock inventory.
        address predictedHandler = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 5);
        nft = new MockAavegotchi(predictedHandler);
        baazaar = new MockBaazaar(address(nft));
        picker = new HolderWeightedPicker(address(token), poolManager);
        escrow = new FlipEscrow(address(nft), address(baazaar), address(picker), operator);
        sink = new FeeSink(address(hook), address(baazaar), address(escrow));
        handler = new MarketHandler(token, nft, baazaar, picker, escrow, sink, operator);
        assertEq(address(handler), predictedHandler, "handler address prediction");
        token.transfer(address(handler), token.totalSupply());
        vm.roll(1_000);

        targetContract(address(handler));
    }

    // ---------------------------------------------------------------------------------------------
    // FeeSink: conservation of ETH
    // ---------------------------------------------------------------------------------------------

    function invariant_sinkBalanceIsCollectedMinusSpent() public view {
        assertEq(sink.totalCollected(), handler.ghostFunded(), "totalCollected tracks every wei sent");
        assertEq(sink.totalSpent(), handler.ghostSpent(), "totalSpent tracks every purchase");
        assertEq(address(sink).balance, sink.totalCollected() - sink.totalSpent(), "sink conserves ETH");
        assertLe(sink.totalSpent(), sink.totalCollected(), "sink never spends more than it got");
        assertEq(sink.buyCount(), handler.ghostBuys(), "buyCount tracks the cranks that succeeded");
        assertEq(sink.pendingPayment(), 0, "no payment is armed between calls");
    }

    function invariant_acquisitionsMatchCranksAndDeliveries() public view {
        assertEq(escrow.acquisitionCount(), handler.ghostBuys() + handler.ghostEscrowDeliveries(), "acquisitions");
    }

    // ---------------------------------------------------------------------------------------------
    // MockBaazaar: ETH equals what sellers are owed; NFTs equal active listings
    // ---------------------------------------------------------------------------------------------

    function invariant_baazaarEthBacksSellerProceeds() public view {
        uint256 owed = 0;
        for (uint256 i = 0; i < handler.sellerCount(); i++) {
            owed += baazaar.proceeds(handler.sellers(i));
        }
        assertEq(owed, handler.ghostOutstandingProceeds(), "proceeds ledger tracks sales minus withdrawals");
        assertEq(address(baazaar).balance, owed, "baazaar holds exactly what it owes");
    }

    function invariant_cheapestAboveTheCapIsNeverBought() public view {
        (bool found,,, uint256 price,) = baazaar.cheapest();
        (bool ok, string memory reason,,,,) = sink.canBuy();
        if (found && price > sink.MAX_BUY_PRICE()) {
            assertFalse(ok, "the crank would buy above the cap");
            if (address(sink).balance >= sink.MIN_BUY_THRESHOLD() && price <= address(sink).balance) {
                assertEq(reason, "cheapest listing above price cap");
            }
        }
    }

    function invariant_activeListingsMatchEscrowedNfts() public view {
        uint256 active = 0;
        uint256 n = baazaar.listingCount();
        for (uint256 id = 1; id <= n; id++) {
            MockBaazaar.Listing memory l = baazaar.getListing(id);
            if (l.active) {
                active += 1;
                assertEq(nft.ownerOf(l.tokenId), address(baazaar), "active listing's NFT is escrowed");
            }
        }
        assertEq(baazaar.activeCount(), active, "activeCount equals the active listings");
        assertLe(active, baazaar.MAX_ACTIVE_LISTINGS(), "cap respected");
        assertEq(nft.balanceOf(address(baazaar)), active, "baazaar holds no NFT beyond its active listings");
    }

    function invariant_cheapestIsTheLowestPricedOldestActiveListing() public view {
        (bool found, uint256 listingId,, uint256 price,) = baazaar.cheapest();
        uint256 n = baazaar.listingCount();
        bool anyActive = false;
        for (uint256 id = 1; id <= n; id++) {
            MockBaazaar.Listing memory l = baazaar.getListing(id);
            if (!l.active) continue;
            anyActive = true;
            assertTrue(found, "an active listing exists but cheapest found none");
            assertLe(price, l.price, "cheapest is not the lowest price");
            if (l.price == price) assertLe(listingId, id, "ties go to the oldest listing");
        }
        assertEq(found, anyActive, "cheapest reports a listing iff one is active");
    }

    // ---------------------------------------------------------------------------------------------
    // FlipEscrow: custody and the state machine
    // ---------------------------------------------------------------------------------------------

    function invariant_escrowHoldsExactlyTheUnresolvedAcquisitions() public view {
        uint256 unresolved = 0;
        uint256 n = escrow.acquisitionCount();
        for (uint256 id = 0; id < n; id++) {
            FlipEscrow.Acquisition memory a = escrow.getAcquisition(id);
            if (a.status == FlipEscrow.Status.Resolved) {
                assertEq(nft.ownerOf(a.tokenId), a.recipient, "resolved NFT is with its recipient");
                if (a.burned) assertEq(a.recipient, DEAD, "burned means the dead address");
                else assertTrue(a.recipient != DEAD && a.recipient != address(0), "airdrop went to a holder");
            } else {
                unresolved += 1;
                assertEq(nft.ownerOf(a.tokenId), address(escrow), "unresolved NFT is in the escrow");
                assertTrue(a.status == FlipEscrow.Status.Pending || a.status == FlipEscrow.Status.Requested, "status");
            }
        }
        assertEq(
            nft.balanceOf(address(escrow)),
            unresolved + handler.ghostStraysInEscrow(),
            "escrow holds nothing beyond open acquisitions and unswept strays"
        );
        assertEq(address(escrow).balance, 0, "escrow never holds ETH");
    }

    function invariant_requestedFlipsFreezeTheBlockBeforeTheRequest() public view {
        uint256 n = escrow.acquisitionCount();
        for (uint256 id = 0; id < n; id++) {
            FlipEscrow.Acquisition memory a = escrow.getAcquisition(id);
            if (a.requestId == bytes32(0)) {
                assertEq(a.pickerSnapshotBlock, 0, "an unbound acquisition carries a snapshot");
                continue;
            }
            assertEq(a.pickerSnapshotBlock + 1, a.requestBlock, "the snapshot is the block before the request");
            assertGe(a.requestBlock, a.receivedBlock, "requested before received");
            if (a.status == FlipEscrow.Status.Resolved && !a.burned) {
                assertGt(picker.weightOfAt(a.recipient, a.pickerSnapshotBlock), 0, "airdrop winner had no weight then");
            }
        }
    }

    function invariant_resolvedAcquisitionsNeverReopen() public view {
        uint256 n = escrow.acquisitionCount();
        for (uint256 id = 0; id < n; id++) {
            if (!handler.ghostResolved(id)) continue;
            FlipEscrow.Acquisition memory a = escrow.getAcquisition(id);
            assertEq(uint8(a.status), uint8(FlipEscrow.Status.Resolved), "a resolved flip reopened");
            assertEq(a.burned, handler.ghostBurned(id), "burn outcome changed");
            assertEq(a.recipient, handler.ghostRecipient(id), "recipient changed");
        }
    }

    function invariant_commitmentsAreFifoAndBoundOnce() public view {
        uint256 n = escrow.commitmentCount();
        uint256 next = escrow.nextCommitment();
        assertLe(next, n, "nextCommitment within range");
        assertEq(escrow.availableCommitments(), n - next, "available commitments");
        uint256 previousBlock = 0;
        for (uint256 i = 0; i < n; i++) {
            FlipEscrow.Commitment memory c = escrow.getCommitment(i);
            assertGe(c.commitBlock, previousBlock, "commit blocks are non-decreasing");
            previousBlock = c.commitBlock;
            assertTrue(c.hash != bytes32(0), "no zero commitment");
            if (i < next) {
                assertTrue(c.bound, "consumed commitment is bound");
                FlipEscrow.Acquisition memory a = escrow.getAcquisition(c.acquisitionId);
                assertEq(a.commitmentIndex, i, "bound acquisition points back at the commitment");
                assertTrue(a.status != FlipEscrow.Status.Pending, "bound acquisition is not pending");
                assertLt(c.commitBlock, a.requestBlock, "commitment predates the block that bound it");
            } else {
                assertFalse(c.bound, "unconsumed commitment is unbound");
            }
        }
        // Every acquisition that left Pending through a commitment owns exactly one of them.
        uint256 bound_ = 0;
        for (uint256 id = 0; id < escrow.acquisitionCount(); id++) {
            FlipEscrow.Acquisition memory a = escrow.getAcquisition(id);
            if (a.requestId != bytes32(0)) {
                bound_ += 1;
                assertEq(escrow.getCommitment(a.commitmentIndex).acquisitionId, id, "commitment points back");
            }
        }
        assertEq(bound_, next, "bound acquisitions equal consumed commitments");
    }

    // ---------------------------------------------------------------------------------------------
    // Picker: stored weights add up
    // ---------------------------------------------------------------------------------------------

    function invariant_pickerWeightsSumToTotal() public view {
        uint256 sum = 0;
        uint256 n = picker.holderCount();
        for (uint256 i = 0; i < n; i++) {
            address h = picker.holderAt(i);
            assertFalse(picker.isExcluded(h), "an excluded address is registered");
            sum += picker.weightOf(h);
        }
        assertEq(picker.totalWeight(), sum, "totalWeight is the sum of stored weights");
        assertEq(picker.prefixWeight(n), sum, "the Fenwick tree agrees");
        assertEq(token.balanceOf(address(picker)), sum, "the picker holds exactly the deposited weights");
        assertEq(sum, handler.ghostDeposited() - handler.ghostWithdrawn(), "weights equal deposits minus withdrawals");
    }

    // ---------------------------------------------------------------------------------------------
    // Token supply never changes
    // ---------------------------------------------------------------------------------------------

    function invariant_tokenSupplyFixed() public view {
        assertEq(token.totalSupply(), 1e27);
    }

    // ---------------------------------------------------------------------------------------------
    // Handler-side expectations
    // ---------------------------------------------------------------------------------------------

    function invariant_noViolations() public {
        uint256 n = handler.violationCount();
        if (n > 0) {
            emit log_named_string("first violation", handler.violations(0));
        }
        assertEq(n, 0, "a handler expectation failed; see the logged violation");
    }

    function afterInvariant() public {
        // Exposure summary for the run log: how often the interesting paths were taken.
        emit log_named_uint("buys", handler.ghostBuys());
        emit log_named_uint("deliveries by third parties", handler.ghostEscrowDeliveries());
        emit log_named_uint("resolved", handler.ghostResolvedCount());
        emit log_named_uint("requestFlip successes", handler.ghostRequestFlipSuccesses());
        emit log_named_uint("cranks refused by the price cap", handler.ghostCapRefusals());
        emit log_named_uint("strays swept", handler.ghostStraysSwept());
    }
}
