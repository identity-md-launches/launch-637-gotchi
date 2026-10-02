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

    function test_pickForfeitsWhenLiveBalanceFellBelowStoredWeight() public {
        _registerTrio();
        vm.prank(carol);
        token.transfer(address(0xBEEF), 1);
        (address winner, uint256 weight) = picker.pick(50e18);
        assertEq(winner, address(0), "stale weight forfeits");
        assertEq(weight, 0);
        // Other holders are unaffected.
        _assertPick(5e18, alice, 10e18);
        // After a refresh carol is eligible again with the live weight.
        picker.refresh(carol);
        _assertPick(50e18, carol, 60e18 - 1);
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
}
