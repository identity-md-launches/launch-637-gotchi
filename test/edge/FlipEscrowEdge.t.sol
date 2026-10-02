// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {GotchiFixture} from "../utils/GotchiFixture.sol";
import {FlipEscrow} from "../../src/FlipEscrow.sol";
import {HolderWeightedPicker} from "../../src/HolderWeightedPicker.sol";

/// @notice A holder that is a contract without `onERC721Received`: an airdrop must still reach it.
contract ContractHolder {
    function register(HolderWeightedPicker picker) external {
        picker.register();
    }
}

/// @notice FlipEscrow edges against the real Baazaar: unusual deliveries, batch commits, permissionless
/// reveal, window boundaries, contract recipients and roll statistics.
/// forge-config: default.fuzz.runs = 512
contract FlipEscrowEdgeTest is GotchiFixture {
    address buyer = makeAddr("buyer");
    address alice = makeAddr("alice");

    function setUp() public override {
        super.setUp();
        vm.deal(buyer, 10 ether);
        vm.roll(100);
    }

    // ---------------------------------------------------------------------------------------------
    // Intake
    // ---------------------------------------------------------------------------------------------

    function test_aThirdPartyPurchaseDeliveredToTheEscrowBecomesAnAcquisition() public {
        (, uint256 tokenId) = mintAndList(seller, 0.5 ether);
        vm.prank(buyer);
        vm.expectEmit(true, false, false, true, address(escrow));
        emit FlipEscrow.AcquisitionReceived(0, tokenId);
        baazaar.buyCheapest{value: 0.5 ether}(address(escrow), 0.5 ether);
        assertEq(escrow.acquisitionCount(), 1);
        assertEq(escrow.getAcquisition(0).tokenId, tokenId);
        assertEq(uint8(escrow.getAcquisition(0).status), uint8(FlipEscrow.Status.Pending));
        assertEq(sink.buyCount(), 0, "the sink did not buy this one");
    }

    function test_anUnsafeTransferCreatesNoAcquisition() public {
        vm.prank(minter);
        uint256 id = nft.mint(alice);
        vm.prank(alice);
        nft.transferFrom(alice, address(escrow), id);
        assertEq(nft.ownerOf(id), address(escrow), "the NFT arrived without a callback");
        assertEq(escrow.acquisitionCount(), 0, "no acquisition exists for it");
        // Nothing can be done with it through the state machine.
        vm.expectRevert(abi.encodeWithSelector(FlipEscrow.UnknownAcquisition.selector, 0));
        escrow.expire(0);
    }

    // ---------------------------------------------------------------------------------------------
    // Commitments
    // ---------------------------------------------------------------------------------------------

    function test_commitManyWithAnEmptyArrayIsANoOp() public {
        vm.prank(operator);
        escrow.commitMany(new bytes32[](0));
        assertEq(escrow.commitmentCount(), 0);
    }

    function test_aZeroHashRejectsTheWholeBatch() public {
        bytes32[] memory hashes = new bytes32[](3);
        hashes[0] = keccak256("a");
        hashes[1] = bytes32(0);
        hashes[2] = keccak256("c");
        vm.prank(operator);
        vm.expectRevert(FlipEscrow.ZeroCommitment.selector);
        escrow.commitMany(hashes);
        assertEq(escrow.commitmentCount(), 0, "nothing from the batch was kept");
    }

    function test_strangersCannotCommitInBatchesEither() public {
        bytes32[] memory hashes = new bytes32[](1);
        hashes[0] = keccak256("a");
        vm.prank(buyer);
        vm.expectRevert(FlipEscrow.NotOperator.selector);
        escrow.commitMany(hashes);
    }

    function test_fiveDeliveriesInOneBlockConsumeFiveCommitmentsInOrder() public {
        bytes32[] memory hashes = new bytes32[](5);
        for (uint256 i = 0; i < 5; i++) {
            hashes[i] = keccak256(abi.encode("fifo", i));
        }
        vm.prank(operator);
        escrow.commitMany(hashes);
        vm.roll(101);
        uint256[] memory ids = new uint256[](5);
        for (uint256 i = 0; i < 5; i++) {
            (, ids[i]) = mintAndList(seller, 0.001 ether);
        }
        vm.deal(address(sink), 0.02 ether);
        for (uint256 i = 0; i < 5; i++) {
            assertEq(sink.triggerBuy(), i);
            FlipEscrow.Acquisition memory a = escrow.getAcquisition(i);
            assertEq(a.tokenId, ids[i], "cheapest ties resolve to the oldest listing");
            assertEq(uint8(a.status), uint8(FlipEscrow.Status.Requested));
            assertEq(a.commitmentIndex, i, "commitments are consumed first in, first out");
            assertEq(escrow.getCommitment(i).acquisitionId, i);
            assertTrue(escrow.getCommitment(i).bound);
        }
        assertEq(escrow.availableCommitments(), 0);
        assertEq(escrow.nextCommitment(), 5);
    }

    // ---------------------------------------------------------------------------------------------
    // Reveal
    // ---------------------------------------------------------------------------------------------

    function test_anyoneWhoKnowsTheSecretMayReveal() public {
        (uint256 acquisitionId, uint256 tokenId, bytes32 secret) = _requestedAcquisition(true);
        vm.prank(buyer);
        escrow.reveal(acquisitionId, secret);
        assertEq(nft.ownerOf(tokenId), DEAD);
    }

    function test_revealOnTheLastBlockOfTheWindowSucceeds() public {
        (uint256 acquisitionId, uint256 tokenId, bytes32 secret) = _requestedAcquisition(true);
        uint256 requestBlock = escrow.getAcquisition(acquisitionId).requestBlock;
        vm.roll(requestBlock + escrow.REVEAL_WINDOW_BLOCKS());
        escrow.reveal(acquisitionId, secret);
        assertEq(nft.ownerOf(tokenId), DEAD);
    }

    function test_theSecretOfAnotherCommitmentIsRejected() public {
        bytes32 secretA = keccak256("secret A");
        bytes32 secretB = keccak256("secret B");
        vm.startPrank(operator);
        escrow.commit(keccak256(abi.encodePacked(secretA)));
        escrow.commit(keccak256(abi.encodePacked(secretB)));
        vm.stopPrank();
        vm.roll(101);
        mintAndList(seller, 0.001 ether);
        mintAndList(seller, 0.001 ether);
        vm.deal(address(sink), 0.02 ether);
        sink.triggerBuy();
        sink.triggerBuy();
        vm.expectRevert(FlipEscrow.BadSecret.selector);
        escrow.reveal(0, secretB);
        vm.expectRevert(FlipEscrow.BadSecret.selector);
        escrow.reveal(1, secretA);
        escrow.reveal(0, secretA);
        escrow.reveal(1, secretB);
        assertEq(uint8(escrow.getAcquisition(0).status), uint8(FlipEscrow.Status.Resolved));
        assertEq(uint8(escrow.getAcquisition(1).status), uint8(FlipEscrow.Status.Resolved));
    }

    function test_airdropToAContractWithoutReceiverStillResolves() public {
        ContractHolder holder = new ContractHolder();
        token.transfer(address(holder), 1_000e18);
        holder.register(picker);
        assertEq(picker.totalWeight(), 1_000e18);

        (uint256 acquisitionId, uint256 tokenId, bytes32 secret) = _requestedAcquisition(false);
        vm.expectEmit(true, true, false, true, address(escrow));
        emit FlipEscrow.Airdropped(tokenId, address(holder), 1_000e18);
        escrow.reveal(acquisitionId, secret);
        assertEq(nft.ownerOf(tokenId), address(holder), "transferFrom, not safeTransferFrom, so the contract gets it");
    }

    function test_resolvedAcquisitionRejectsEveryTransition() public {
        (uint256 acquisitionId,, bytes32 secret) = _requestedAcquisition(true);
        escrow.reveal(acquisitionId, secret);
        bytes memory err =
            abi.encodeWithSelector(FlipEscrow.InvalidStatus.selector, acquisitionId, FlipEscrow.Status.Resolved);
        vm.expectRevert(err);
        escrow.requestFlip(acquisitionId);
        vm.expectRevert(err);
        escrow.reveal(acquisitionId, secret);
        vm.expectRevert(err);
        escrow.expire(acquisitionId);
        vm.roll(block.number + escrow.REVEAL_WINDOW_BLOCKS() + 1);
        vm.expectRevert(err);
        escrow.expire(acquisitionId);
    }

    function test_revealAfterAForcedBurnIsRefused() public {
        (uint256 acquisitionId, uint256 tokenId, bytes32 secret) = _requestedAcquisition(false);
        vm.roll(block.number + escrow.REVEAL_WINDOW_BLOCKS() + 1);
        escrow.expire(acquisitionId);
        assertEq(nft.ownerOf(tokenId), DEAD);
        vm.expectRevert(
            abi.encodeWithSelector(FlipEscrow.InvalidStatus.selector, acquisitionId, FlipEscrow.Status.Resolved)
        );
        escrow.reveal(acquisitionId, secret);
    }

    function test_pendingAcquisitionCannotBeRevealedOrExpiredEarly() public {
        mintAndList(seller, 0.001 ether);
        vm.deal(address(sink), 0.02 ether);
        uint256 acquisitionId = sink.triggerBuy();
        assertEq(uint8(escrow.getAcquisition(acquisitionId).status), uint8(FlipEscrow.Status.Pending));
        vm.expectRevert(
            abi.encodeWithSelector(FlipEscrow.InvalidStatus.selector, acquisitionId, FlipEscrow.Status.Pending)
        );
        escrow.reveal(acquisitionId, bytes32(uint256(1)));
        vm.roll(block.number + escrow.PENDING_TIMEOUT_BLOCKS());
        vm.expectRevert(abi.encodeWithSelector(FlipEscrow.NotExpired.selector, acquisitionId));
        escrow.expire(acquisitionId);
    }

    function test_unknownAcquisitionIdsRevertEverywhere() public {
        bytes memory err = abi.encodeWithSelector(FlipEscrow.UnknownAcquisition.selector, 0);
        vm.expectRevert(err);
        escrow.requestFlip(0);
        vm.expectRevert(err);
        escrow.reveal(0, bytes32(uint256(1)));
        vm.expectRevert(err);
        escrow.expire(0);
        vm.expectRevert(err);
        escrow.getAcquisition(0);
        vm.expectRevert();
        escrow.getCommitment(0);
    }

    // ---------------------------------------------------------------------------------------------
    // Roll statistics and request ids
    // ---------------------------------------------------------------------------------------------

    /// forge-config: default.fuzz.runs = 32
    function testFuzz_exactlyHalfOfAnyTenThousandConsecutiveRollsBurn(uint256 start) public view {
        start = bound(start, 0, type(uint256).max - 10_000);
        uint256 burns = 0;
        for (uint256 i = 0; i < 10_000; i++) {
            if (escrow.isBurnRoll(start + i)) burns += 1;
        }
        assertEq(burns, 5_000, "FLIP_BURN_BPS = 5000 means exactly half of every full cycle burns");
    }

    function testFuzz_requestIdDependsOnEveryInput(uint256 a, uint256 t, uint256 c, bytes32 h, uint256 bump)
        public
        view
    {
        bump = bound(bump, 1, type(uint128).max);
        bytes32 base = escrow.computeRequestId(a, t, c, h);
        assertTrue(base != escrow.computeRequestId(a ^ bump, t, c, h), "acquisition id");
        assertTrue(base != escrow.computeRequestId(a, t ^ bump, c, h), "token id");
        assertTrue(base != escrow.computeRequestId(a, t, c ^ bump, h), "commitment index");
        assertTrue(base != escrow.computeRequestId(a, t, c, h ^ bytes32(bump)), "hash");
        assertTrue(base != bytes32(0));
    }

    function testFuzz_rollIsAPureFunctionOfSecretAndRequestId(bytes32 secret, bytes32 requestId) public view {
        uint256 roll = escrow.rollFor(secret, requestId);
        assertEq(roll, escrow.rollFor(secret, requestId));
        assertEq(roll, uint256(keccak256(abi.encode(secret, requestId))));
        assertEq(escrow.isBurnRoll(roll), roll % 10_000 < 5_000);
    }

    // ---------------------------------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------------------------------

    /// @dev Lists a gotchi, commits a secret whose roll burns (or not) for the acquisition it will become,
    /// and lets the sink buy it in a later block so the commitment binds at receipt.
    function _requestedAcquisition(bool wantBurn)
        internal
        returns (uint256 acquisitionId, uint256 tokenId, bytes32 secret)
    {
        acquisitionId = escrow.acquisitionCount();
        uint256 commitmentIndex = escrow.commitmentCount();
        (, tokenId) = mintAndList(seller, 0.001 ether);
        bytes32 hash;
        (secret, hash) = findSecret(acquisitionId, tokenId, commitmentIndex, wantBurn);
        vm.prank(operator);
        escrow.commit(hash);
        vm.roll(block.number + 1);
        vm.deal(address(sink), 0.02 ether);
        assertEq(sink.triggerBuy(), acquisitionId);
        assertEq(uint8(escrow.getAcquisition(acquisitionId).status), uint8(FlipEscrow.Status.Requested));
    }
}
