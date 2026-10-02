// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {MockAavegotchi} from "../src/MockAavegotchi.sol";
import {HolderWeightedPicker} from "../src/HolderWeightedPicker.sol";
import {FlipEscrow} from "../src/FlipEscrow.sol";

/// @notice Unit tests for the escrow in isolation: a plain address plays the Baazaar.
contract FlipEscrowTest is Test {
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;

    LaunchToken token;
    MockAavegotchi nft;
    HolderWeightedPicker picker;
    FlipEscrow escrow;

    address operator = makeAddr("operator");
    address minter = makeAddr("minter");
    address baazaar = makeAddr("baazaar");
    address poolManager = makeAddr("poolManager");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() public {
        token = new LaunchToken();
        nft = new MockAavegotchi(minter);
        picker = new HolderWeightedPicker(address(token), poolManager);
        escrow = new FlipEscrow(address(nft), baazaar, address(picker), operator);
        vm.roll(100);
    }

    // ---------------------------------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------------------------------

    function _mintToBaazaar() internal returns (uint256 tokenId) {
        vm.prank(minter);
        tokenId = nft.mint(baazaar);
    }

    function _deliver(uint256 tokenId) internal {
        vm.prank(baazaar);
        nft.safeTransferFrom(baazaar, address(escrow), tokenId);
    }

    function _commit(bytes32 hash) internal {
        vm.prank(operator);
        escrow.commit(hash);
    }

    function _findSecret(uint256 acquisitionId, uint256 tokenId, uint256 commitmentIndex, bool wantBurn)
        internal
        view
        returns (bytes32 secret, bytes32 hash)
    {
        for (uint256 i = 1; i < 10_000; i++) {
            secret = keccak256(abi.encode("secret", i));
            hash = keccak256(abi.encodePacked(secret));
            bytes32 requestId = escrow.computeRequestId(acquisitionId, tokenId, commitmentIndex, hash);
            if (escrow.isBurnRoll(escrow.rollFor(secret, requestId)) == wantBurn) return (secret, hash);
        }
        revert("no secret");
    }

    function _registerHolders() internal {
        token.transfer(alice, 25e18);
        token.transfer(bob, 75e18);
        vm.prank(alice);
        picker.register();
        vm.prank(bob);
        picker.register();
    }

    // ---------------------------------------------------------------------------------------------
    // Construction and roles
    // ---------------------------------------------------------------------------------------------

    function test_constantsAndWiring() public view {
        assertEq(escrow.FLIP_BURN_BPS(), 5_000);
        assertEq(escrow.BURN_ADDRESS(), DEAD);
        assertEq(address(escrow.NFT()), address(nft));
        assertEq(escrow.BAAZAAR(), baazaar);
        assertEq(address(escrow.PICKER()), address(picker));
        assertEq(escrow.OPERATOR(), operator);
        assertEq(escrow.acquisitionCount(), 0);
        assertEq(escrow.commitmentCount(), 0);
    }

    function test_constructorRejectsZeroAddresses() public {
        vm.expectRevert(FlipEscrow.ZeroAddress.selector);
        new FlipEscrow(address(0), baazaar, address(picker), operator);
        vm.expectRevert(FlipEscrow.ZeroAddress.selector);
        new FlipEscrow(address(nft), address(0), address(picker), operator);
        vm.expectRevert(FlipEscrow.ZeroAddress.selector);
        new FlipEscrow(address(nft), baazaar, address(0), operator);
        vm.expectRevert(FlipEscrow.ZeroAddress.selector);
        new FlipEscrow(address(nft), baazaar, address(picker), address(0));
    }

    function test_onlyOperatorCommits() public {
        vm.expectRevert(FlipEscrow.NotOperator.selector);
        escrow.commit(bytes32(uint256(1)));
        vm.prank(operator);
        vm.expectRevert(FlipEscrow.ZeroCommitment.selector);
        escrow.commit(bytes32(0));

        vm.prank(operator);
        vm.expectEmit(true, false, false, true, address(escrow));
        emit FlipEscrow.RandomnessCommitted(0, bytes32(uint256(1)));
        escrow.commit(bytes32(uint256(1)));
        bytes32[] memory more = new bytes32[](2);
        more[0] = bytes32(uint256(2));
        more[1] = bytes32(uint256(3));
        vm.prank(operator);
        escrow.commitMany(more);
        assertEq(escrow.commitmentCount(), 3);
        assertEq(escrow.availableCommitments(), 3);
        FlipEscrow.Commitment memory c = escrow.getCommitment(2);
        assertEq(c.hash, bytes32(uint256(3)));
        assertEq(c.commitBlock, 100);
        assertFalse(c.bound);
    }

    // ---------------------------------------------------------------------------------------------
    // Intake
    // ---------------------------------------------------------------------------------------------

    function test_onlyTheNftContractMayDeliver() public {
        vm.expectRevert(FlipEscrow.NotTheNft.selector);
        escrow.onERC721Received(address(this), baazaar, 1, "");
    }

    function test_onlyTransfersFromTheBaazaarAreAccepted() public {
        vm.prank(minter);
        uint256 id = nft.mint(alice);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(FlipEscrow.NotFromBaazaar.selector, alice));
        nft.safeTransferFrom(alice, address(escrow), id);
        assertEq(escrow.acquisitionCount(), 0);
    }

    function test_deliveryWithoutCommitmentStaysPending() public {
        uint256 id = _mintToBaazaar();
        vm.expectEmit(true, false, false, true, address(escrow));
        emit FlipEscrow.AcquisitionReceived(0, id);
        _deliver(id);
        FlipEscrow.Acquisition memory a = escrow.getAcquisition(0);
        assertEq(uint8(a.status), uint8(FlipEscrow.Status.Pending));
        assertEq(a.tokenId, id);
        assertEq(a.receivedBlock, 100);
        assertEq(nft.ownerOf(id), address(escrow));
        vm.expectRevert(FlipEscrow.NoCommitmentAvailable.selector);
        escrow.requestFlip(0);
    }

    function test_deliveryBindsAnEarlierCommitment() public {
        bytes32 hash = keccak256("x");
        _commit(hash);
        vm.roll(101);
        uint256 id = _mintToBaazaar();
        bytes32 requestId = escrow.computeRequestId(0, id, 0, hash);
        vm.expectEmit(true, false, false, true, address(escrow));
        emit FlipEscrow.FlipRequested(0, id, requestId);
        _deliver(id);

        FlipEscrow.Acquisition memory a = escrow.getAcquisition(0);
        assertEq(uint8(a.status), uint8(FlipEscrow.Status.Requested));
        assertEq(a.commitmentIndex, 0);
        assertEq(a.requestBlock, 101);
        assertEq(a.requestId, requestId);
        FlipEscrow.Commitment memory c = escrow.getCommitment(0);
        assertTrue(c.bound);
        assertEq(c.acquisitionId, 0);
        assertEq(escrow.nextCommitment(), 1);
        assertEq(escrow.availableCommitments(), 0);
        vm.expectRevert(abi.encodeWithSelector(FlipEscrow.InvalidStatus.selector, 0, FlipEscrow.Status.Requested));
        escrow.requestFlip(0);
    }

    function test_sameBlockCommitmentIsNotEligibleForThatDelivery() public {
        _commit(keccak256("same block"));
        uint256 id = _mintToBaazaar();
        _deliver(id);
        assertEq(uint8(escrow.getAcquisition(0).status), uint8(FlipEscrow.Status.Pending));
        // ...but it serves the next delivery, which happens later.
        vm.roll(101);
        uint256 id2 = _mintToBaazaar();
        _deliver(id2);
        assertEq(uint8(escrow.getAcquisition(1).status), uint8(FlipEscrow.Status.Requested));
        assertEq(escrow.getAcquisition(1).commitmentIndex, 0);
        // A commitment made in the binding block is still too new for the pending one...
        _commit(keccak256("later"));
        vm.expectRevert(FlipEscrow.NoCommitmentAvailable.selector);
        escrow.requestFlip(0);
        // ...but one block later anyone can bind it.
        vm.roll(102);
        bytes32 requestId = escrow.computeRequestId(0, id, 1, keccak256("later"));
        vm.expectEmit(true, false, false, true, address(escrow));
        emit FlipEscrow.FlipRequested(0, id, requestId);
        escrow.requestFlip(0);
        FlipEscrow.Acquisition memory a = escrow.getAcquisition(0);
        assertEq(uint8(a.status), uint8(FlipEscrow.Status.Requested));
        assertEq(a.commitmentIndex, 1);
        assertEq(a.requestBlock, 102);
        assertEq(a.receivedBlock, 100);
        assertEq(escrow.availableCommitments(), 0);
    }

    function test_pendingAcquisitionBindsACommitmentMadeAfterItsReceipt() public {
        // Empty queue at delivery; the operator commits afterwards; a keeper binds and the flip resolves.
        _registerHolders();
        uint256 id = _mintToBaazaar();
        _deliver(id);
        (bytes32 secret, bytes32 hash) = _findSecret(0, id, 0, false);
        vm.roll(150);
        _commit(hash);
        vm.expectRevert(FlipEscrow.NoCommitmentAvailable.selector);
        escrow.requestFlip(0); // same block as the commitment
        vm.roll(151);
        escrow.requestFlip(0);
        FlipEscrow.Acquisition memory a = escrow.getAcquisition(0);
        assertEq(uint8(a.status), uint8(FlipEscrow.Status.Requested));
        assertEq(a.pickerVersion, picker.version(), "eligible set frozen at the request");

        escrow.reveal(0, secret);
        address owner = nft.ownerOf(id);
        assertTrue(owner == alice || owner == bob, "a pending acquisition still gets its 50/50");
        // Once bound it can no longer be expired as pending.
        vm.roll(100 + escrow.PENDING_TIMEOUT_BLOCKS() + 1);
        vm.expectRevert(abi.encodeWithSelector(FlipEscrow.InvalidStatus.selector, 0, FlipEscrow.Status.Resolved));
        escrow.expire(0);
    }

    function test_requestFlipConsumesCommitmentsInOrderAcrossPendingAndNewAcquisitions() public {
        uint256 id0 = _mintToBaazaar();
        _deliver(id0); // pending, nothing queued
        vm.roll(101);
        _commit(keccak256("c0"));
        _commit(keccak256("c1"));
        vm.roll(102);
        uint256 id1 = _mintToBaazaar();
        _deliver(id1); // takes c0 immediately
        assertEq(escrow.getAcquisition(1).commitmentIndex, 0);
        escrow.requestFlip(0); // the older pending one takes c1
        assertEq(escrow.getAcquisition(0).commitmentIndex, 1);
        assertEq(escrow.availableCommitments(), 0);
    }

    function test_requestFlipBindsAPendingAcquisitionLater() public {
        // Two commitments queued, two deliveries in the same later block consume them in order.
        _commit(keccak256("a"));
        _commit(keccak256("b"));
        vm.roll(105);
        uint256 id1 = _mintToBaazaar();
        uint256 id2 = _mintToBaazaar();
        _deliver(id1);
        _deliver(id2);
        assertEq(escrow.getAcquisition(0).commitmentIndex, 0);
        assertEq(escrow.getAcquisition(1).commitmentIndex, 1);
        assertEq(escrow.availableCommitments(), 0);
    }

    // ---------------------------------------------------------------------------------------------
    // Reveal: burn path
    // ---------------------------------------------------------------------------------------------

    function test_revealBurnsOnABurnRoll() public {
        uint256 expectedId = nft.nextTokenId();
        (bytes32 secret, bytes32 hash) = _findSecret(0, expectedId, 0, true);
        _commit(hash);
        vm.roll(101);
        uint256 id = _mintToBaazaar();
        assertEq(id, expectedId);
        _deliver(id);
        _registerHolders();

        bytes32 requestId = escrow.getAcquisition(0).requestId;
        uint256 roll = escrow.rollFor(secret, requestId);
        vm.expectEmit(true, false, false, true, address(escrow));
        emit FlipEscrow.FlipRevealed(0, roll);
        vm.expectEmit(true, true, false, true, address(escrow));
        emit FlipEscrow.FlipResolved(0, id, true, DEAD);
        vm.expectEmit(true, true, false, true, address(escrow));
        emit FlipEscrow.Burned(id, DEAD);
        escrow.reveal(0, secret);

        assertEq(nft.ownerOf(id), DEAD);
        FlipEscrow.Acquisition memory a = escrow.getAcquisition(0);
        assertEq(uint8(a.status), uint8(FlipEscrow.Status.Resolved));
        assertTrue(a.burned);
        assertEq(a.recipient, DEAD);
    }

    // ---------------------------------------------------------------------------------------------
    // Reveal: airdrop path
    // ---------------------------------------------------------------------------------------------

    function test_revealAirdropsToTheWeightedPick() public {
        _registerHolders();
        uint256 expectedId = nft.nextTokenId();
        (bytes32 secret, bytes32 hash) = _findSecret(0, expectedId, 0, false);
        _commit(hash);
        vm.roll(101);
        uint256 id = _mintToBaazaar();
        _deliver(id);

        uint256 roll = escrow.rollFor(secret, escrow.getAcquisition(0).requestId);
        (address expectedWinner, uint256 expectedWeight) = picker.pick(roll);
        assertTrue(expectedWinner == alice || expectedWinner == bob);

        vm.expectEmit(true, true, false, true, address(escrow));
        emit FlipEscrow.FlipResolved(0, id, false, expectedWinner);
        vm.expectEmit(true, true, false, true, address(escrow));
        emit FlipEscrow.Airdropped(id, expectedWinner, expectedWeight);
        escrow.reveal(0, secret);

        assertEq(nft.ownerOf(id), expectedWinner);
        FlipEscrow.Acquisition memory a = escrow.getAcquisition(0);
        assertFalse(a.burned);
        assertEq(a.recipient, expectedWinner);
    }

    function test_airdropRollWithoutEligibleHoldersBurns() public {
        uint256 expectedId = nft.nextTokenId();
        (bytes32 secret, bytes32 hash) = _findSecret(0, expectedId, 0, false);
        _commit(hash);
        vm.roll(101);
        uint256 id = _mintToBaazaar();
        _deliver(id);
        vm.expectEmit(true, true, false, true, address(escrow));
        emit FlipEscrow.FlipResolved(0, id, true, DEAD);
        escrow.reveal(0, secret);
        assertEq(nft.ownerOf(id), DEAD);
    }

    function test_airdropRollWithEveryDrawStaleBurns() public {
        _registerHolders();
        uint256 expectedId = nft.nextTokenId();
        (bytes32 secret, bytes32 hash) = _findSecret(0, expectedId, 0, false);
        _commit(hash);
        vm.roll(101);
        uint256 id = _mintToBaazaar();
        _deliver(id);
        // Both registered holders move one wei away without refreshing: every draw is stale.
        vm.prank(alice);
        token.transfer(address(0xBEEF), 1);
        vm.prank(bob);
        token.transfer(address(0xBEEF), 1);
        vm.expectEmit(true, true, false, true, address(escrow));
        emit FlipEscrow.FlipResolved(0, id, true, DEAD);
        escrow.reveal(0, secret);
        assertEq(nft.ownerOf(id), DEAD, "stale weights forfeit to a burn");
    }

    function test_airdropRollWithOneStaleHolderRedrawsToTheOther() public {
        _registerHolders();
        uint256 expectedId = nft.nextTokenId();
        (bytes32 secret, bytes32 hash) = _findSecret(0, expectedId, 0, false);
        _commit(hash);
        vm.roll(101);
        uint256 id = _mintToBaazaar();
        _deliver(id);
        uint256 roll = escrow.rollFor(secret, escrow.getAcquisition(0).requestId);
        (address firstDraw,) = picker.pick(roll);
        address other = firstDraw == alice ? bob : alice;
        // The first draw's holder moves one wei away without refreshing; the re-draws can only land on
        // the other holder (or forfeit if every one of them hits the stale holder again).
        vm.prank(firstDraw);
        token.transfer(address(0xBEEF), 1);
        (address expected,) = picker.pickAt(escrow.getAcquisition(0).pickerVersion, roll);
        assertTrue(expected == other || expected == address(0));
        uint256 versionBefore = picker.version();
        escrow.reveal(0, secret);
        assertEq(nft.ownerOf(id), expected == address(0) ? DEAD : expected, "re-drawn past the stale holder");
        assertEq(picker.weightOf(firstDraw), token.balanceOf(firstDraw), "the stale entry was refreshed");
        assertGt(picker.version(), versionBefore);
    }

    // ---------------------------------------------------------------------------------------------
    // Reveal: the eligible set is frozen at the request
    // ---------------------------------------------------------------------------------------------

    function test_registrationAfterTheRequestCannotWinThatFlip() public {
        _registerHolders();
        uint256 expectedId = nft.nextTokenId();
        (bytes32 secret, bytes32 hash) = _findSecret(0, expectedId, 0, false);
        _commit(hash);
        vm.roll(101);
        uint256 id = _mintToBaazaar();
        _deliver(id);
        uint256 frozen = escrow.getAcquisition(0).pickerVersion;
        assertEq(frozen, picker.version());

        // The reveal is public: a late entrant funds exactly the weight that would catch the roll against
        // the *current* registry and registers before the reveal lands.
        uint256 roll = escrow.rollFor(secret, escrow.getAcquisition(0).requestId);
        uint256 honest = picker.totalWeight();
        address attacker = makeAddr("attacker");
        uint256 w = 0;
        for (uint256 candidate = 1e15; candidate <= honest; candidate += 1e15) {
            if (roll % (honest + candidate) >= honest) {
                w = candidate;
                break;
            }
        }
        assertGt(w, 0);
        token.transfer(attacker, w);
        vm.prank(attacker);
        picker.register();
        (address liveWinner,) = picker.pick(roll);
        assertEq(liveWinner, attacker, "against the live registry the attacker would win");
        (address frozenWinner, uint256 frozenWeight) = picker.pickAt(frozen, roll);
        assertTrue(frozenWinner == alice || frozenWinner == bob);

        vm.expectEmit(true, true, false, true, address(escrow));
        emit FlipEscrow.Airdropped(id, frozenWinner, frozenWeight);
        escrow.reveal(0, secret);
        assertEq(nft.ownerOf(id), frozenWinner, "the frozen registry decides");
    }

    function test_refreshAfterTheRequestCannotChangeTheWinner() public {
        _registerHolders();
        uint256 expectedId = nft.nextTokenId();
        (bytes32 secret, bytes32 hash) = _findSecret(0, expectedId, 0, false);
        _commit(hash);
        vm.roll(101);
        uint256 id = _mintToBaazaar();
        _deliver(id);
        uint256 roll = escrow.rollFor(secret, escrow.getAcquisition(0).requestId);
        (address frozenWinner,) = picker.pickAt(escrow.getAcquisition(0).pickerVersion, roll);
        address loser = frozenWinner == alice ? bob : alice;
        // The loser pumps their weight after the request: irrelevant to this flip.
        token.transfer(loser, 1_000_000e18);
        picker.refresh(loser);
        escrow.reveal(0, secret);
        assertEq(nft.ownerOf(id), frozenWinner);
    }

    // ---------------------------------------------------------------------------------------------
    // Stray NFTs
    // ---------------------------------------------------------------------------------------------

    function test_strayNftPushedInWithTransferFromCanOnlyBeBurned() public {
        vm.prank(minter);
        uint256 id = nft.mint(alice);
        vm.prank(alice);
        nft.transferFrom(alice, address(escrow), id); // no callback: no acquisition
        assertEq(escrow.acquisitionCount(), 0);
        (bool found,) = escrow.latestAcquisitionOf(id);
        assertFalse(found);
        vm.expectEmit(true, false, false, true, address(escrow));
        emit FlipEscrow.StraySwept(id);
        vm.expectEmit(true, true, false, true, address(escrow));
        emit FlipEscrow.Burned(id, DEAD);
        escrow.sweepStray(id);
        assertEq(nft.ownerOf(id), DEAD);
    }

    function test_sweepStrayRefusesOpenAcquisitionsAndTokensNotHeld() public {
        uint256 id = _mintToBaazaar();
        _deliver(id); // pending acquisition: not a stray
        vm.expectRevert(abi.encodeWithSelector(FlipEscrow.NotStray.selector, id));
        escrow.sweepStray(id);
        vm.prank(minter);
        uint256 other = nft.mint(alice);
        vm.expectRevert(abi.encodeWithSelector(FlipEscrow.NotStray.selector, other));
        escrow.sweepStray(other);
        // Resolved and returned: a stray again.
        vm.roll(100 + escrow.PENDING_TIMEOUT_BLOCKS() + 1);
        escrow.expire(0);
        (bool found, uint256 acquisitionId) = escrow.latestAcquisitionOf(id);
        assertTrue(found);
        assertEq(acquisitionId, 0);
        vm.prank(DEAD);
        nft.transferFrom(DEAD, address(escrow), id);
        escrow.sweepStray(id);
        assertEq(nft.ownerOf(id), DEAD);
    }

    // ---------------------------------------------------------------------------------------------
    // Reveal: failure paths
    // ---------------------------------------------------------------------------------------------

    function test_revealRejectsWrongSecretAndWrongStatus() public {
        (bytes32 secret, bytes32 hash) = _findSecret(0, 1, 0, true);
        _commit(hash);
        vm.roll(101);
        uint256 id = _mintToBaazaar();
        _deliver(id);
        vm.expectRevert(FlipEscrow.BadSecret.selector);
        escrow.reveal(0, keccak256("wrong"));
        vm.expectRevert(abi.encodeWithSelector(FlipEscrow.UnknownAcquisition.selector, 5));
        escrow.reveal(5, secret);
        escrow.reveal(0, secret);
        vm.expectRevert(abi.encodeWithSelector(FlipEscrow.InvalidStatus.selector, 0, FlipEscrow.Status.Resolved));
        escrow.reveal(0, secret);
        vm.expectRevert(abi.encodeWithSelector(FlipEscrow.InvalidStatus.selector, 0, FlipEscrow.Status.Resolved));
        escrow.expire(0);
    }

    function test_revealOfAPendingAcquisitionIsRefused() public {
        uint256 id = _mintToBaazaar();
        _deliver(id);
        vm.expectRevert(abi.encodeWithSelector(FlipEscrow.InvalidStatus.selector, 0, FlipEscrow.Status.Pending));
        escrow.reveal(0, keccak256("whatever"));
    }

    function test_withheldRevealIsForceBurnedAfterTheWindow() public {
        (bytes32 secret, bytes32 hash) = _findSecret(0, 1, 0, false);
        _registerHolders();
        _commit(hash);
        vm.roll(101);
        uint256 id = _mintToBaazaar();
        _deliver(id);

        vm.expectRevert(abi.encodeWithSelector(FlipEscrow.NotExpired.selector, 0));
        escrow.expire(0);
        vm.roll(101 + escrow.REVEAL_WINDOW_BLOCKS());
        vm.expectRevert(abi.encodeWithSelector(FlipEscrow.NotExpired.selector, 0));
        escrow.expire(0);
        // Still revealable on the last block of the window.
        vm.roll(101 + escrow.REVEAL_WINDOW_BLOCKS() + 1);
        vm.expectRevert(abi.encodeWithSelector(FlipEscrow.RevealWindowClosed.selector, 0));
        escrow.reveal(0, secret);

        vm.expectEmit(true, false, false, true, address(escrow));
        emit FlipEscrow.FlipExpired(0);
        vm.expectEmit(true, true, false, true, address(escrow));
        emit FlipEscrow.FlipResolved(0, id, true, DEAD);
        vm.expectEmit(true, true, false, true, address(escrow));
        emit FlipEscrow.Burned(id, DEAD);
        escrow.expire(0);
        assertEq(nft.ownerOf(id), DEAD, "forced burn, even though the roll would have airdropped");
    }

    function test_pendingAcquisitionIsForceBurnedAfterTheTimeout() public {
        uint256 id = _mintToBaazaar();
        _deliver(id);
        vm.roll(100 + escrow.PENDING_TIMEOUT_BLOCKS());
        vm.expectRevert(abi.encodeWithSelector(FlipEscrow.NotExpired.selector, 0));
        escrow.expire(0);
        vm.roll(100 + escrow.PENDING_TIMEOUT_BLOCKS() + 1);
        escrow.expire(0);
        assertEq(nft.ownerOf(id), DEAD);
        assertEq(uint8(escrow.getAcquisition(0).status), uint8(FlipEscrow.Status.Resolved));
    }

    function test_rollMathIsFiftyFifty() public view {
        assertTrue(escrow.isBurnRoll(0));
        assertTrue(escrow.isBurnRoll(4_999));
        assertFalse(escrow.isBurnRoll(5_000));
        assertFalse(escrow.isBurnRoll(9_999));
        assertTrue(escrow.isBurnRoll(10_000));
        bytes32 requestId = keccak256("r");
        assertEq(
            escrow.rollFor(bytes32(uint256(1)), requestId),
            uint256(keccak256(abi.encode(bytes32(uint256(1)), requestId)))
        );
    }

    function test_requestIdBindsChainContractAcquisitionTokenAndCommitment() public view {
        bytes32 base = escrow.computeRequestId(0, 1, 0, keccak256("h"));
        assertEq(
            base,
            keccak256(abi.encode(address(escrow), block.chainid, uint256(0), uint256(1), uint256(0), keccak256("h")))
        );
        assertTrue(base != escrow.computeRequestId(1, 1, 0, keccak256("h")));
        assertTrue(base != escrow.computeRequestId(0, 2, 0, keccak256("h")));
        assertTrue(base != escrow.computeRequestId(0, 1, 1, keccak256("h")));
        assertTrue(base != escrow.computeRequestId(0, 1, 0, keccak256("other")));
    }
}
