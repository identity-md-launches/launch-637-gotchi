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
    uint256 public ghostStray;
    uint256 public ghostRequestFlipSuccesses;
    uint256 public ghostResolvedCount;
    mapping(uint256 acquisitionId => bool) public ghostResolved;
    mapping(uint256 acquisitionId => bool) public ghostBurned;
    mapping(uint256 acquisitionId => address) public ghostRecipient;

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

    function strayEthToBaazaar(uint256 amount) external count("strayEthToBaazaar") {
        amount = bound(amount, 1, 0.001 ether);
        vm.deal(address(this), amount);
        (bool ok,) = address(baazaar).call{value: amount}("");
        _check(ok, "baazaar refused stray ETH");
        ghostStray += amount;
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
        (bool ok,,, uint256 tokenId, uint256 price, address s) = sink.canBuy();
        uint256 balanceBefore = address(sink).balance;
        uint256 acquisitionsBefore = escrow.acquisitionCount();
        uint256 owedBefore = s == address(0) ? 0 : baazaar.proceeds(s);
        try sink.triggerBuy() returns (uint256 acquisitionId) {
            _check(ok, "triggerBuy succeeded although canBuy said no");
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

    function requestFlip(uint256 acquisitionSeed) external count("requestFlip") {
        uint256 n = escrow.acquisitionCount();
        if (n == 0) return;
        uint256 id = acquisitionSeed % n;
        FlipEscrow.Status status = escrow.getAcquisition(id).status;
        try escrow.requestFlip(id) {
            _check(status == FlipEscrow.Status.Pending, "requestFlip succeeded on a non-pending acquisition");
            _check(escrow.getAcquisition(id).status == FlipEscrow.Status.Requested, "requestFlip did not bind");
            ghostRequestFlipSuccesses += 1;
        } catch {}
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
        if (!expectBurn) {
            (address winner,) = picker.pick(roll);
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

    function register(uint256 holderSeed) external count("register") {
        address h = holders[holderSeed % holders.length];
        bool expectOk = !picker.isRegistered(h) && token.balanceOf(h) > 0;
        vm.prank(h);
        try picker.register() {
            _check(expectOk, "register succeeded for an ineligible holder");
            _check(picker.weightOf(h) == token.balanceOf(h), "registered weight is not the balance");
        } catch {
            _check(!expectOk, "register reverted for an eligible holder");
        }
    }

    function refresh(uint256 holderSeed) external count("refresh") {
        address h = holders[holderSeed % holders.length];
        bool registered = picker.isRegistered(h);
        try picker.refresh(h) {
            _check(registered, "refreshed an unregistered holder");
            _check(picker.weightOf(h) == token.balanceOf(h), "refreshed weight is not the live balance");
        } catch {
            _check(!registered, "refresh reverted for a registered holder");
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
        assertEq(address(baazaar).balance, owed + handler.ghostStray(), "baazaar holds exactly what it owes");
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
        assertEq(nft.balanceOf(address(escrow)), unresolved, "escrow holds nothing else");
        assertEq(address(escrow).balance, 0, "escrow never holds ETH");
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
                assertLt(c.commitBlock, a.receivedBlock, "commitment predates the acquisition it serves");
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
    }
}
