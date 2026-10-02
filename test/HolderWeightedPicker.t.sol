// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {HolderWeightedPicker} from "../src/HolderWeightedPicker.sol";

contract HolderWeightedPickerTest is Test {
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;

    LaunchToken token;
    HolderWeightedPicker picker;
    address poolManager = makeAddr("poolManager");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");

    function setUp() public {
        token = new LaunchToken();
        picker = new HolderWeightedPicker(address(token), poolManager);
    }

    function _fundAndRegister(address holder, uint256 amount) internal {
        token.transfer(holder, amount);
        vm.prank(holder);
        picker.register();
    }

    function _registerTrio() internal {
        _fundAndRegister(alice, 10e18);
        _fundAndRegister(bob, 30e18);
        _fundAndRegister(carol, 60e18);
    }

    // ---------------------------------------------------------------------------------------------
    // Registration and exclusions
    // ---------------------------------------------------------------------------------------------

    function test_constructorRejectsZeroAddresses() public {
        vm.expectRevert(HolderWeightedPicker.ZeroAddress.selector);
        new HolderWeightedPicker(address(0), poolManager);
        vm.expectRevert(HolderWeightedPicker.ZeroAddress.selector);
        new HolderWeightedPicker(address(token), address(0));
    }

    function test_registerRecordsBalanceAsWeight() public {
        token.transfer(alice, 10e18);
        vm.prank(alice);
        vm.expectEmit(true, false, false, true, address(picker));
        emit HolderWeightedPicker.HolderRegistered(alice, 10e18);
        picker.register();
        assertTrue(picker.isRegistered(alice));
        assertEq(picker.weightOf(alice), 10e18);
        assertEq(picker.totalWeight(), 10e18);
        assertEq(picker.holderCount(), 1);
        assertEq(picker.holderAt(0), alice);
        assertEq(picker.prefixWeight(1), 10e18);
    }

    function test_registerRefusesZeroBalances() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(HolderWeightedPicker.ZeroBalance.selector, alice));
        picker.register();
        assertFalse(picker.isRegistered(alice));
    }

    function test_registerRefusesExcludedAddresses() public {
        token.transfer(DEAD, 1e18);
        token.transfer(poolManager, 1e18);
        token.transfer(address(picker), 1e18);
        assertTrue(picker.isExcluded(DEAD));
        assertTrue(picker.isExcluded(poolManager));
        assertTrue(picker.isExcluded(address(0)));
        assertTrue(picker.isExcluded(address(picker)));
        assertFalse(picker.isExcluded(alice));

        vm.prank(DEAD);
        vm.expectRevert(abi.encodeWithSelector(HolderWeightedPicker.Excluded.selector, DEAD));
        picker.register();
        vm.prank(poolManager);
        vm.expectRevert(abi.encodeWithSelector(HolderWeightedPicker.Excluded.selector, poolManager));
        picker.register();
        vm.prank(address(picker));
        vm.expectRevert(abi.encodeWithSelector(HolderWeightedPicker.Excluded.selector, address(picker)));
        picker.register();
        assertEq(picker.totalWeight(), 0);
    }

    function test_registerTwiceReverts() public {
        _fundAndRegister(alice, 10e18);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(HolderWeightedPicker.AlreadyRegistered.selector, alice));
        picker.register();
    }

    function test_refreshRequiresRegistration() public {
        vm.expectRevert(abi.encodeWithSelector(HolderWeightedPicker.NotRegistered.selector, alice));
        picker.refresh(alice);
    }

    function test_refreshTracksBalanceUpAndDown() public {
        _registerTrio();
        token.transfer(alice, 5e18);
        vm.expectEmit(true, false, false, true, address(picker));
        emit HolderWeightedPicker.WeightRefreshed(alice, 10e18, 15e18);
        picker.refresh(alice);
        assertEq(picker.weightOf(alice), 15e18);
        assertEq(picker.totalWeight(), 105e18);
        assertEq(picker.prefixWeight(3), 105e18);

        vm.prank(bob);
        token.transfer(carol, 30e18);
        picker.refresh(bob);
        assertEq(picker.weightOf(bob), 0);
        assertEq(picker.totalWeight(), 75e18);
        picker.refresh(carol);
        assertEq(picker.weightOf(carol), 90e18);
        assertEq(picker.totalWeight(), 105e18);
        assertEq(picker.prefixWeight(1), 15e18);
        assertEq(picker.prefixWeight(2), 15e18);
        assertEq(picker.prefixWeight(3), 105e18);
        // Unchanged balance: a no-op refresh.
        picker.refresh(carol);
        assertEq(picker.totalWeight(), 105e18);
    }

    // ---------------------------------------------------------------------------------------------
    // Deterministic selection
    // ---------------------------------------------------------------------------------------------

    function test_pickIsEmptyWithoutHolders() public view {
        (address winner, uint256 weight) = picker.pick(12345);
        assertEq(winner, address(0));
        assertEq(weight, 0);
    }

    function test_pickFollowsCumulativeWeightRanges() public {
        _registerTrio();
        // total = 100e18: alice [0, 10e18), bob [10e18, 40e18), carol [40e18, 100e18)
        _assertPick(0, alice, 10e18);
        _assertPick(10e18 - 1, alice, 10e18);
        _assertPick(10e18, bob, 30e18);
        _assertPick(40e18 - 1, bob, 30e18);
        _assertPick(40e18, carol, 60e18);
        _assertPick(100e18 - 1, carol, 60e18);
        // Randomness wraps modulo the total.
        _assertPick(100e18, alice, 10e18);
        _assertPick(100e18 + 10e18, bob, 30e18);
        _assertPick(type(uint256).max, _expectedFor(type(uint256).max % 100e18), 0);
    }

    function test_pickIsDeterministic() public {
        _registerTrio();
        (address w1, uint256 wt1) = picker.pick(777e18);
        (address w2, uint256 wt2) = picker.pick(777e18);
        assertEq(w1, w2);
        assertEq(wt1, wt2);
    }

    function test_pickSkipsHoldersRefreshedToZero() public {
        _registerTrio();
        vm.prank(bob);
        token.transfer(address(0xBEEF), 30e18);
        picker.refresh(bob);
        // total = 70e18: alice [0, 10e18), carol [10e18, 70e18)
        _assertPick(10e18, carol, 60e18);
        _assertPick(69e18, carol, 60e18);
        _assertPick(9e18, alice, 10e18);
        for (uint256 r = 0; r < 70; r++) {
            (address winner,) = picker.pick(r * 1e18);
            assertTrue(winner != bob, "zero-weight holder must never win");
        }
    }

    function test_pickRedrawsWhenLiveBalanceFellBelowStoredWeight() public {
        _registerTrio();
        vm.prank(carol);
        token.transfer(address(0xBEEF), 1);
        // The first draw (50e18) lands on carol, whose weight is stale; the picker re-draws deterministically.
        (address winner, uint256 weight) = picker.pick(50e18);
        (address expected, uint256 expectedWeight) = _expectedWithRedraws(50e18, carol);
        assertEq(winner, expected, "re-draw sequence");
        assertEq(weight, expectedWeight);
        assertTrue(winner != carol, "a stale holder never wins");
        // Other holders are unaffected.
        _assertPick(5e18, alice, 10e18);
        // After a refresh carol is eligible again with the live weight.
        picker.refresh(carol);
        _assertPick(50e18, carol, 60e18 - 1);
    }

    function test_pickForfeitsOnlyWhenEveryDrawIsStale() public {
        _registerTrio();
        vm.startPrank(alice);
        token.transfer(address(0xBEEF), 1);
        vm.stopPrank();
        vm.prank(bob);
        token.transfer(address(0xBEEF), 1);
        vm.prank(carol);
        token.transfer(address(0xBEEF), 1);
        (address winner, uint256 weight) = picker.pick(50e18);
        assertEq(winner, address(0), "every draw stale: forfeit");
        assertEq(weight, 0);
    }

    function test_staleSybilEntriesDoNotTurnHonestAirdropsIntoBurns() public {
        // One 100-token bag registered through ten wallets leaves nine stale entries behind.
        _fundAndRegister(alice, 100e18);
        address bag = address(uint160(0x5000));
        token.transfer(bag, 100e18);
        for (uint256 i = 0; i < 10; i++) {
            address next = address(uint160(0x5000 + i + 1));
            vm.startPrank(bag);
            picker.register();
            if (i < 9) token.transfer(next, 100e18);
            vm.stopPrank();
            if (i < 9) bag = next;
        }
        assertEq(picker.totalWeight(), 1_100e18);
        // Without re-draws alice would win 10 of 110 flips and 90 would burn. The escrow resolves through
        // `drawAt`, which re-draws past stale entries and refreshes them away, so the registry converges to
        // the two live holders (alice and the wallet holding the bag) within the first few flips.
        uint256 aliceWins = 0;
        uint256 burns = 0;
        for (uint256 r = 0; r < 110; r++) {
            (address winner,) = picker.drawAt(picker.version(), uint256(keccak256(abi.encode("flip", r))));
            if (winner == alice) aliceWins++;
            if (winner == address(0)) burns++;
        }
        assertGt(aliceWins, 40, "alice keeps a real share of the airdrops");
        assertLt(burns, 5, "stale entries rarely turn into burns");
        assertEq(picker.totalWeight(), 200e18, "the stale entries were refreshed to zero");
        // A view-only pick keeps the same semantics minus the cleanup.
        (address viewWinner,) = picker.pick(0);
        assertEq(viewWinner, alice);
    }

    function test_drawAtMatchesPickAtAndOnlyRefreshesStaleHolders() public {
        _registerTrio();
        uint256 frozen = picker.version();
        vm.prank(carol);
        token.transfer(address(0xBEEF), 1);
        (address expected, uint256 expectedWeight) = picker.pickAt(frozen, 50e18);
        (address winner, uint256 weight) = picker.drawAt(frozen, 50e18);
        assertEq(winner, expected);
        assertEq(weight, expectedWeight);
        assertEq(picker.weightOf(carol), 60e18 - 1, "carol was refreshed when her stale entry was drawn");
        assertEq(picker.weightOf(alice), 10e18);
        assertEq(picker.weightOf(bob), 30e18);
        assertEq(picker.totalWeightAt(frozen), 100e18, "the snapshot is untouched");
        // No stale holders: no refreshes, no version change.
        uint256 before = picker.version();
        picker.drawAt(picker.version(), 5e18);
        assertEq(picker.version(), before);
    }

    // ---------------------------------------------------------------------------------------------
    // Versioned snapshots
    // ---------------------------------------------------------------------------------------------

    function test_versionBumpsOnEveryEffectiveMutation() public {
        assertEq(picker.version(), 0);
        _registerTrio();
        assertEq(picker.version(), 3);
        picker.refresh(alice); // unchanged balance: no new version
        assertEq(picker.version(), 3);
        token.transfer(alice, 1e18);
        picker.refresh(alice);
        assertEq(picker.version(), 4);
        assertEq(picker.holderCountAt(0), 0);
        assertEq(picker.holderCountAt(2), 2);
        assertEq(picker.holderCountAt(4), 3);
        assertEq(picker.totalWeightAt(1), 10e18);
        assertEq(picker.totalWeightAt(3), 100e18);
        assertEq(picker.totalWeightAt(4), 101e18);
        assertEq(picker.totalWeightAt(999), 101e18, "future versions read the latest state");
        assertEq(picker.weightOfAt(alice, 0), 0);
        assertEq(picker.weightOfAt(alice, 3), 10e18);
        assertEq(picker.weightOfAt(alice, 4), 11e18);
    }

    function test_pickAtIgnoresLaterRegistrationsAndRefreshes() public {
        _registerTrio();
        uint256 frozen = picker.version();
        // alice [0,10), bob [10,40), carol [40,100) at the frozen version.
        _fundAndRegister(makeAddr("late"), 1_000_000e18);
        token.transfer(alice, 1_000_000e18);
        picker.refresh(alice);
        (address winner, uint256 weight) = picker.pickAt(frozen, 50e18);
        assertEq(winner, carol);
        assertEq(weight, 60e18, "the snapshot weight, not the live one");
        (winner, weight) = picker.pickAt(frozen, 5e18);
        assertEq(winner, alice);
        assertEq(weight, 10e18);
        (winner,) = picker.pickAt(frozen, 100e18 + 15e18);
        assertEq(winner, bob, "modulo the snapshot total");
        // The live pick sees the new state: late's range starts after alice's refreshed 1,000,010 tokens
        // plus bob's and carol's.
        (winner,) = picker.pick(1_000_100e18 + 1);
        assertEq(winner, makeAddr("late"));
        (winner,) = picker.pick(200e18);
        assertEq(winner, alice);
    }

    function test_pickAtBeforeAnyRegistrationIsEmpty() public {
        _registerTrio();
        (address winner, uint256 weight) = picker.pickAt(0, 12345);
        assertEq(winner, address(0));
        assertEq(weight, 0);
    }

    function test_pickAtStillConfirmsTheLiveBalanceAgainstTheSnapshotWeight() public {
        _registerTrio();
        uint256 frozen = picker.version();
        vm.prank(carol);
        token.transfer(address(0xBEEF), 1);
        picker.refresh(carol); // live state is consistent again, but the snapshot says 60e18
        (address winner,) = picker.pickAt(frozen, 50e18);
        assertTrue(winner != carol, "carol holds less than her snapshot weight");
        (address live,) = picker.pick(50e18);
        assertEq(live, carol, "against the current version she is fine");
    }

    function test_registryHasNoCapacityCap() public {
        // Far more than the old 2^16 would be impractical in a test; what matters is that nothing in the
        // tree depends on a fixed size: positions past any power of two keep selecting correctly.
        uint256 n = 300;
        for (uint256 i = 0; i < n; i++) {
            _fundAndRegister(address(uint160(0x2000 + i)), 1e18);
        }
        assertEq(picker.holderCount(), n);
        assertEq(picker.totalWeight(), n * 1e18);
        for (uint256 i = 0; i < n; i += 7) {
            (address winner, uint256 weight) = picker.pick(i * 1e18 + 5);
            assertEq(winner, address(uint160(0x2000 + i)));
            assertEq(weight, 1e18);
        }
        (address last,) = picker.pick(n * 1e18 - 1);
        assertEq(last, address(uint160(0x2000 + n - 1)));
    }

    function test_pickToleratesLiveBalanceAboveStoredWeight() public {
        _registerTrio();
        token.transfer(alice, 1_000e18);
        (address winner, uint256 weight) = picker.pick(5e18);
        assertEq(winner, alice);
        assertEq(weight, 10e18, "wins with the stored weight until refreshed");
    }

    function testFuzz_pickAlwaysReturnsARegisteredHolderWithPositiveWeight(uint256 randomness) public {
        _registerTrio();
        (address winner, uint256 weight) = picker.pick(randomness);
        assertTrue(winner == alice || winner == bob || winner == carol);
        assertEq(weight, picker.weightOf(winner));
        assertGt(weight, 0);
        assertEq(winner, _expectedFor(randomness % 100e18));
    }

    function test_manyHoldersStayConsistentWithPrefixSums() public {
        uint256 n = 40;
        uint256 running = 0;
        for (uint256 i = 0; i < n; i++) {
            address holder = address(uint160(0x1000 + i));
            _fundAndRegister(holder, (i + 1) * 1e18);
            running += (i + 1) * 1e18;
            assertEq(picker.prefixWeight(i + 1), running);
        }
        assertEq(picker.totalWeight(), running);
        // Target just below each boundary lands on that holder.
        uint256 cumulative = 0;
        for (uint256 i = 0; i < n; i++) {
            cumulative += (i + 1) * 1e18;
            (address winner, uint256 weight) = picker.pick(cumulative - 1);
            assertEq(winner, address(uint160(0x1000 + i)));
            assertEq(weight, (i + 1) * 1e18);
        }
    }

    function _assertPick(uint256 randomness, address expected, uint256 expectedWeight) internal view {
        (address winner, uint256 weight) = picker.pick(randomness);
        assertEq(winner, expected, "winner");
        if (expectedWeight > 0) assertEq(weight, expectedWeight, "weight");
    }

    function _expectedFor(uint256 target) internal view returns (address) {
        if (target < 10e18) return alice;
        if (target < 40e18) return bob;
        return carol;
    }

    /// @dev Replays the picker's draw sequence for the trio with `stale` forfeiting every time.
    function _expectedWithRedraws(uint256 randomness, address stale) internal view returns (address, uint256) {
        for (uint256 draw = 0; draw < picker.MAX_DRAWS(); draw++) {
            uint256 roll = draw == 0 ? randomness : uint256(keccak256(abi.encode(randomness, draw)));
            address candidate = _expectedFor(roll % 100e18);
            if (candidate != stale) return (candidate, picker.weightOf(candidate));
        }
        return (address(0), 0);
    }
}
