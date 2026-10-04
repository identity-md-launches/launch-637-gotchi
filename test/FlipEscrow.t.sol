// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/IERC6093.sol";
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

    function _deposit(address holder, uint256 amount) internal {
        token.transfer(holder, amount);
        vm.startPrank(holder);
        token.approve(address(picker), amount);
        picker.deposit(amount);
        vm.stopPrank();
    }

    function _registerHolders() internal {
        _deposit(alice, 25e18);
        _deposit(bob, 75e18);
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
        assertEq(a.pickerSnapshotBlock, 150, "eligible set frozen at the end of the block before the request");

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

    function test_airdropRollWhenEveryDepositWasWithdrawnBeforeTheSnapshotBurns() public {
        _registerHolders();
        vm.prank(alice);
        picker.withdraw(25e18);
        vm.prank(bob);
        picker.withdraw(75e18);
        uint256 expectedId = nft.nextTokenId();
        (bytes32 secret, bytes32 hash) = _findSecret(0, expectedId, 0, false);
        _commit(hash);
        vm.roll(101);
        uint256 id = _mintToBaazaar();
        _deliver(id);
        vm.expectEmit(true, true, false, true, address(escrow));
        emit FlipEscrow.FlipResolved(0, id, true, DEAD);
        escrow.reveal(0, secret);
        assertEq(nft.ownerOf(id), DEAD, "registered holders with zero weight at the snapshot: burn");
    }

    // ---------------------------------------------------------------------------------------------
    // Reveal: the eligible set and the weights are frozen at the block before the request
    // ---------------------------------------------------------------------------------------------

    function test_depositAfterTheRequestCannotWinThatFlip() public {
        _registerHolders();
        uint256 expectedId = nft.nextTokenId();
        (bytes32 secret, bytes32 hash) = _findSecret(0, expectedId, 0, false);
        _commit(hash);
        vm.roll(101);
        uint256 id = _mintToBaazaar();
        _deliver(id);
        uint256 frozen = escrow.getAcquisition(0).pickerSnapshotBlock;
        assertEq(frozen, 100);

        // The reveal is public: a late entrant funds exactly the weight that would catch the roll against
        // the *current* registry and deposits before the reveal lands.
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
        _deposit(attacker, w);
        (address liveWinner,) = picker.pick(roll);
        assertEq(liveWinner, attacker, "against the live registry the attacker would win");
        (address frozenWinner, uint256 frozenWeight) = picker.pickAt(frozen, roll);
        assertTrue(frozenWinner == alice || frozenWinner == bob);

        vm.expectEmit(true, true, false, true, address(escrow));
        emit FlipEscrow.Airdropped(id, frozenWinner, frozenWeight);
        escrow.reveal(0, secret);
        assertEq(nft.ownerOf(id), frozenWinner, "the frozen registry decides");
    }

    function test_depositInTheRequestBlockDoesNotCountForThatFlip() public {
        // Alice deposits a block ahead; bob deposits a huge weight in the request block itself, before the
        // delivery (the flash-loan shape: deposit, trigger the purchase, withdraw, all in one block).
        _deposit(alice, 25e18);
        uint256 expectedId = nft.nextTokenId();
        (bytes32 secret, bytes32 hash) = _findSecret(0, expectedId, 0, false);
        _commit(hash);
        vm.roll(101);
        _deposit(bob, 1_000_000e18);
        uint256 id = _mintToBaazaar();
        _deliver(id);
        vm.prank(bob);
        picker.withdraw(1_000_000e18);
        assertEq(escrow.getAcquisition(0).pickerSnapshotBlock, 100);
        assertEq(picker.totalWeightAt(100), 25e18, "only alice had weight at the end of block 100");
        escrow.reveal(0, secret);
        assertEq(nft.ownerOf(id), alice, "the same-block depositor never counted");
    }

    function test_withdrawalAfterTheRequestCannotChangeTheWinner() public {
        _registerHolders();
        uint256 expectedId = nft.nextTokenId();
        (bytes32 secret, bytes32 hash) = _findSecret(0, expectedId, 0, false);
        _commit(hash);
        vm.roll(101);
        uint256 id = _mintToBaazaar();
        _deliver(id);
        uint256 roll = escrow.rollFor(secret, escrow.getAcquisition(0).requestId);
        (address frozenWinner, uint256 frozenWeight) = picker.pickAt(escrow.getAcquisition(0).pickerSnapshotBlock, roll);
        address loser = frozenWinner == alice ? bob : alice;
        // Everyone withdraws and the loser re-deposits a huge weight after the request: irrelevant.
        vm.roll(102);
        vm.prank(alice);
        picker.withdraw(25e18);
        vm.prank(bob);
        picker.withdraw(75e18);
        _deposit(loser, 1_000_000e18);
        (address liveWinner,) = picker.pick(roll);
        assertEq(liveWinner, loser, "against the live registry the loser would win");
        vm.expectEmit(true, true, false, true, address(escrow));
        emit FlipEscrow.Airdropped(id, frozenWinner, frozenWeight);
        escrow.reveal(0, secret);
        assertEq(nft.ownerOf(id), frozenWinner, "the snapshot decides, with the snapshot weight");
    }

    function test_oneBagBehindManyWalletsCannotBeSteeredIntoWinning() public {
        // The reviewer's scenario: alice holds 100 GOTCHI; the attacker tries to register the SAME 100 GOTCHI
        // through ten wallets and then move the bag to whichever wallet the public roll selects. With
        // custody, depositing locks the bag, so only one of the ten wallets ever carries weight, and moving
        // it after the request is a checkpoint the frozen snapshot does not see.
        uint256 bag = 100e18;
        _deposit(alice, bag);
        address[10] memory sybils;
        for (uint256 i = 0; i < 10; i++) {
            sybils[i] = makeAddr(string.concat("sybil", vm.toString(i)));
        }
        _deposit(sybils[0], bag);
        for (uint256 i = 1; i < 10; i++) {
            vm.prank(sybils[i - 1]);
            vm.expectRevert(
                abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, sybils[i - 1], 0, bag)
            );
            token.transfer(sybils[i], bag);
            vm.startPrank(sybils[i]);
            token.approve(address(picker), bag);
            vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, sybils[i], 0, bag));
            picker.deposit(bag);
            vm.stopPrank();
        }
        assertEq(picker.totalWeight(), 2 * bag, "100 GOTCHI of attacker tokens carry 100 of weight, not 1,000");

        uint256 expectedId = nft.nextTokenId();
        (bytes32 secret, bytes32 hash) = _findSecret(0, expectedId, 0, false);
        _commit(hash);
        vm.roll(101);
        uint256 id = _mintToBaazaar();
        _deliver(id);
        uint256 frozen = escrow.getAcquisition(0).pickerSnapshotBlock;
        uint256 roll = escrow.rollFor(secret, escrow.getAcquisition(0).requestId);
        (address frozenWinner,) = picker.pickAt(frozen, roll);
        assertTrue(frozenWinner == alice || frozenWinner == sybils[0]);

        // The reveal is in the mempool. The attacker moves the bag to another wallet (withdraw, transfer,
        // deposit) ahead of it. Nothing changes for this flip.
        vm.roll(102);
        vm.prank(sybils[0]);
        picker.withdraw(bag);
        vm.prank(sybils[0]);
        token.transfer(sybils[7], bag);
        vm.startPrank(sybils[7]);
        token.approve(address(picker), bag);
        picker.deposit(bag);
        vm.stopPrank();
        escrow.reveal(0, secret);
        assertEq(nft.ownerOf(id), frozenWinner, "the snapshot winner, chosen before the roll was knowable");
        for (uint256 i = 1; i < 10; i++) {
            assertTrue(nft.ownerOf(id) != sybils[i], "a wallet with no deposit at the snapshot cannot win");
        }
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
