// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/IERC6093.sol";
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
        vm.roll(100);
    }

    function _fundAndDeposit(address holder, uint256 amount) internal {
        token.transfer(holder, amount);
        vm.startPrank(holder);
        token.approve(address(picker), amount);
        picker.deposit(amount);
        vm.stopPrank();
    }

    function _depositTrio() internal {
        _fundAndDeposit(alice, 10e18);
        _fundAndDeposit(bob, 30e18);
        _fundAndDeposit(carol, 60e18);
    }

    function _assertConserved() internal view {
        assertEq(picker.totalWeight(), token.balanceOf(address(picker)), "total weight == custodied tokens");
    }

    // ---------------------------------------------------------------------------------------------
    // Deposits and exclusions
    // ---------------------------------------------------------------------------------------------

    function test_constructorRejectsZeroAddresses() public {
        vm.expectRevert(HolderWeightedPicker.ZeroAddress.selector);
        new HolderWeightedPicker(address(0), poolManager);
        vm.expectRevert(HolderWeightedPicker.ZeroAddress.selector);
        new HolderWeightedPicker(address(token), address(0));
    }

    function test_depositCustodiesTokensAndRecordsWeight() public {
        token.transfer(alice, 10e18);
        vm.startPrank(alice);
        token.approve(address(picker), 10e18);
        vm.expectEmit(true, false, false, true, address(picker));
        emit HolderWeightedPicker.Deposited(alice, 10e18, 10e18);
        uint256 received = picker.deposit(10e18);
        vm.stopPrank();
        assertEq(received, 10e18);
        assertTrue(picker.isRegistered(alice));
        assertEq(picker.weightOf(alice), 10e18);
        assertEq(picker.totalWeight(), 10e18);
        assertEq(picker.holderCount(), 1);
        assertEq(picker.holderAt(0), alice);
        assertEq(picker.prefixWeight(1), 10e18);
        assertEq(token.balanceOf(alice), 0, "the tokens left the wallet");
        assertEq(token.balanceOf(address(picker)), 10e18, "and sit in the picker");
        _assertConserved();
    }

    function test_depositRequiresBalanceAndApproval() public {
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(picker), 0, 1e18)
        );
        picker.deposit(1e18);
        vm.startPrank(alice);
        token.approve(address(picker), 1e18);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 0, 1e18));
        picker.deposit(1e18);
        vm.stopPrank();
        assertFalse(picker.isRegistered(alice));
        assertEq(picker.totalWeight(), 0);
    }

    function test_depositRefusesZeroAmount() public {
        vm.prank(alice);
        vm.expectRevert(HolderWeightedPicker.ZeroAmount.selector);
        picker.deposit(0);
    }

    function test_depositRefusesExcludedAddresses() public {
        assertTrue(picker.isExcluded(DEAD));
        assertTrue(picker.isExcluded(poolManager));
        assertTrue(picker.isExcluded(address(0)));
        assertTrue(picker.isExcluded(address(picker)));
        assertFalse(picker.isExcluded(alice));

        token.transfer(DEAD, 1e18);
        token.transfer(poolManager, 1e18);
        vm.startPrank(DEAD);
        token.approve(address(picker), 1e18);
        vm.expectRevert(abi.encodeWithSelector(HolderWeightedPicker.Excluded.selector, DEAD));
        picker.deposit(1e18);
        vm.stopPrank();
        vm.startPrank(poolManager);
        token.approve(address(picker), 1e18);
        vm.expectRevert(abi.encodeWithSelector(HolderWeightedPicker.Excluded.selector, poolManager));
        picker.deposit(1e18);
        vm.stopPrank();
        vm.prank(address(picker));
        vm.expectRevert(abi.encodeWithSelector(HolderWeightedPicker.Excluded.selector, address(picker)));
        picker.deposit(1e18);
        assertEq(picker.totalWeight(), 0);
    }

    function test_secondDepositAddsToTheSamePosition() public {
        _depositTrio();
        token.transfer(alice, 5e18);
        vm.startPrank(alice);
        token.approve(address(picker), 5e18);
        vm.expectEmit(true, false, false, true, address(picker));
        emit HolderWeightedPicker.Deposited(alice, 5e18, 15e18);
        picker.deposit(5e18);
        vm.stopPrank();
        assertEq(picker.weightOf(alice), 15e18);
        assertEq(picker.totalWeight(), 105e18);
        assertEq(picker.holderCount(), 3, "no new position");
        assertEq(picker.prefixWeight(1), 15e18);
        assertEq(picker.prefixWeight(3), 105e18);
        _assertConserved();
    }

    function test_plainTransfersToThePickerCarryNoWeight() public {
        _depositTrio();
        token.transfer(address(picker), 1_000e18);
        assertEq(picker.totalWeight(), 100e18, "only deposits count");
        (address winner,) = picker.pick(50e18);
        assertEq(winner, carol);
    }

    // ---------------------------------------------------------------------------------------------
    // Withdrawals
    // ---------------------------------------------------------------------------------------------

    function test_withdrawReturnsTokensAndLowersWeight() public {
        _depositTrio();
        vm.prank(bob);
        vm.expectEmit(true, false, false, true, address(picker));
        emit HolderWeightedPicker.Withdrawn(bob, 10e18, 20e18);
        picker.withdraw(10e18);
        assertEq(picker.weightOf(bob), 20e18);
        assertEq(token.balanceOf(bob), 10e18);
        assertEq(picker.totalWeight(), 90e18);
        assertEq(picker.prefixWeight(2), 30e18);
        assertEq(picker.prefixWeight(3), 90e18);
        _assertConserved();

        // Everything: weight zero, still registered, never selected.
        vm.prank(bob);
        picker.withdraw(20e18);
        assertEq(picker.weightOf(bob), 0);
        assertTrue(picker.isRegistered(bob));
        assertEq(token.balanceOf(bob), 30e18);
        assertEq(picker.totalWeight(), 70e18);
        // total = 70e18: alice [0, 10e18), carol [10e18, 70e18)
        _assertPick(10e18, carol, 60e18);
        _assertPick(69e18, carol, 60e18);
        _assertPick(9e18, alice, 10e18);
        for (uint256 r = 0; r < 70; r++) {
            (address winner,) = picker.pick(r * 1e18);
            assertTrue(winner != bob, "zero-weight holder must never win");
        }
        _assertConserved();
    }

    function test_withdrawRejectsTooMuchZeroAndUnregistered() public {
        _depositTrio();
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(HolderWeightedPicker.InsufficientWeight.selector, alice, 10e18, 10e18 + 1)
        );
        picker.withdraw(10e18 + 1);
        vm.prank(alice);
        vm.expectRevert(HolderWeightedPicker.ZeroAmount.selector);
        picker.withdraw(0);
        vm.prank(makeAddr("nobody"));
        vm.expectRevert(abi.encodeWithSelector(HolderWeightedPicker.NotRegistered.selector, makeAddr("nobody")));
        picker.withdraw(1);
        assertEq(picker.totalWeight(), 100e18);
    }

    function test_redepositAfterFullWithdrawalReusesThePosition() public {
        _depositTrio();
        vm.prank(alice);
        picker.withdraw(10e18);
        vm.startPrank(alice);
        token.approve(address(picker), 10e18);
        picker.deposit(10e18);
        vm.stopPrank();
        assertEq(picker.holderCount(), 3);
        assertEq(picker.weightOf(alice), 10e18);
        _assertPick(5e18, alice, 10e18);
        _assertConserved();
    }

    // ---------------------------------------------------------------------------------------------
    // One token backs one weight
    // ---------------------------------------------------------------------------------------------

    function test_depositedTokensCannotBeRegisteredAgainThroughAnotherWallet() public {
        // The sybil pattern from the review: one bag, many wallets. With custody the bag is gone from the
        // wallet the moment it carries weight, so the second wallet has nothing to deposit.
        _fundAndDeposit(alice, 100e18);
        address s0 = makeAddr("sybil0");
        address s1 = makeAddr("sybil1");
        _fundAndDeposit(s0, 100e18);
        vm.prank(s0);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, s0, 0, 100e18));
        token.transfer(s1, 100e18);
        assertEq(picker.totalWeight(), 200e18, "100 GOTCHI of attacker tokens carry 100 of weight");

        // Moving the weight means withdrawing (a checkpoint) and depositing elsewhere: the total is unchanged.
        vm.prank(s0);
        picker.withdraw(100e18);
        vm.prank(s0);
        token.transfer(s1, 100e18);
        vm.startPrank(s1);
        token.approve(address(picker), 100e18);
        picker.deposit(100e18);
        vm.stopPrank();
        assertEq(picker.totalWeight(), 200e18);
        assertEq(picker.weightOf(s0), 0);
        assertEq(picker.weightOf(s1), 100e18);
        _assertConserved();
    }

    // ---------------------------------------------------------------------------------------------
    // Deterministic selection
    // ---------------------------------------------------------------------------------------------

    function test_pickIsEmptyWithoutDeposits() public view {
        (address winner, uint256 weight) = picker.pick(12345);
        assertEq(winner, address(0));
        assertEq(weight, 0);
    }

    function test_pickFollowsCumulativeWeightRanges() public {
        _depositTrio();
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
        _depositTrio();
        (address w1, uint256 wt1) = picker.pick(777e18);
        (address w2, uint256 wt2) = picker.pick(777e18);
        assertEq(w1, w2);
        assertEq(wt1, wt2);
    }

    function test_registryHasNoCapacityCap() public {
        // What matters is that nothing in the tree depends on a fixed size: positions past any power of
        // two keep selecting correctly.
        uint256 n = 300;
        for (uint256 i = 0; i < n; i++) {
            _fundAndDeposit(address(uint160(0x2000 + i)), 1e18);
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

    function testFuzz_pickAlwaysReturnsADepositorWithPositiveWeight(uint256 randomness) public {
        _depositTrio();
        (address winner, uint256 weight) = picker.pick(randomness);
        assertTrue(winner == alice || winner == bob || winner == carol);
        assertEq(weight, picker.weightOf(winner));
        assertGt(weight, 0);
        assertEq(winner, _expectedFor(randomness % 100e18));
    }

    function testFuzz_depositsAndWithdrawalsConserveTokens(uint96 a, uint96 b, uint96 wa, uint96 wb) public {
        a = uint96(bound(a, 1, 1_000_000e18));
        b = uint96(bound(b, 1, 1_000_000e18));
        wa = uint96(bound(wa, 0, a));
        wb = uint96(bound(wb, 0, b));
        _fundAndDeposit(alice, a);
        _fundAndDeposit(bob, b);
        if (wa > 0) {
            vm.prank(alice);
            picker.withdraw(wa);
        }
        if (wb > 0) {
            vm.prank(bob);
            picker.withdraw(wb);
        }
        assertEq(picker.weightOf(alice), uint256(a) - wa);
        assertEq(picker.weightOf(bob), uint256(b) - wb);
        assertEq(picker.totalWeight(), uint256(a) - wa + uint256(b) - wb);
        assertEq(token.balanceOf(alice), wa);
        assertEq(token.balanceOf(bob), wb);
        _assertConserved();
        if (picker.totalWeight() > 0) {
            (address winner, uint256 weight) = picker.pick(uint256(keccak256(abi.encode(a, b))));
            assertGt(weight, 0);
            assertEq(weight, picker.weightOf(winner));
        }
    }

    function test_manyHoldersStayConsistentWithPrefixSums() public {
        uint256 n = 40;
        uint256 running = 0;
        for (uint256 i = 0; i < n; i++) {
            address holder = address(uint160(0x1000 + i));
            _fundAndDeposit(holder, (i + 1) * 1e18);
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

    // ---------------------------------------------------------------------------------------------
    // Block snapshots
    // ---------------------------------------------------------------------------------------------

    function test_snapshotViewsAnswerPerBlock() public {
        _fundAndDeposit(alice, 10e18); // block 100
        vm.roll(101);
        _fundAndDeposit(bob, 30e18);
        vm.roll(103);
        _fundAndDeposit(carol, 60e18);
        vm.prank(alice);
        picker.withdraw(4e18); // same block as carol's deposit
        vm.roll(110);

        assertEq(picker.holderCountAt(99), 0);
        assertEq(picker.totalWeightAt(99), 0);
        assertEq(picker.holderCountAt(100), 1);
        assertEq(picker.totalWeightAt(100), 10e18);
        assertEq(picker.holderCountAt(102), 2, "a block without changes reads the latest earlier state");
        assertEq(picker.totalWeightAt(102), 40e18);
        assertEq(picker.holderCountAt(103), 3);
        assertEq(picker.totalWeightAt(103), 96e18, "several changes in one block collapse into one checkpoint");
        assertEq(picker.totalWeightAt(999), 96e18, "future blocks read the latest state");
        assertEq(picker.weightOfAt(alice, 99), 0);
        assertEq(picker.weightOfAt(alice, 100), 10e18);
        assertEq(picker.weightOfAt(alice, 102), 10e18);
        assertEq(picker.weightOfAt(alice, 103), 6e18);
        assertEq(picker.weightOfAt(carol, 102), 0);
        assertEq(picker.weightOfAt(carol, 103), 60e18);
    }

    function test_pickAtIgnoresLaterDepositsAndWithdrawals() public {
        _depositTrio(); // block 100
        uint256 frozen = vm.getBlockNumber();
        vm.roll(101);
        // alice [0,10), bob [10,40), carol [40,100) at the frozen block.
        _fundAndDeposit(makeAddr("late"), 1_000_000e18);
        _fundAndDeposit(alice, 1_000_000e18);
        vm.prank(carol);
        picker.withdraw(60e18);
        (address winner, uint256 weight) = picker.pickAt(frozen, 50e18);
        assertEq(winner, carol, "carol's weight at the snapshot still counts");
        assertEq(weight, 60e18, "the snapshot weight, not the live one");
        (winner, weight) = picker.pickAt(frozen, 5e18);
        assertEq(winner, alice);
        assertEq(weight, 10e18);
        (winner,) = picker.pickAt(frozen, 100e18 + 15e18);
        assertEq(winner, bob, "modulo the snapshot total");
        // The live pick sees the new state: alice [0, 1,000,010), bob [.., +30), late [.., +1,000,000), carol empty.
        (winner,) = picker.pick(1_000_040e18 + 1);
        assertEq(winner, makeAddr("late"));
        (winner,) = picker.pick(200e18);
        assertEq(winner, alice);
        for (uint256 r = 0; r < 20; r++) {
            (winner,) = picker.pick(uint256(keccak256(abi.encode(r))));
            assertTrue(winner != carol, "carol has no live weight");
        }
    }

    function test_pickAtTheBlockBeforeADepositExcludesIt() public {
        _fundAndDeposit(alice, 10e18); // block 100
        vm.roll(101);
        _fundAndDeposit(bob, 1_000_000e18); // block 101
        // The escrow resolves with pickAt(requestBlock - 1): a deposit in the request block never counts.
        for (uint256 r = 0; r < 20; r++) {
            (address winner, uint256 weight) = picker.pickAt(100, uint256(keccak256(abi.encode(r))));
            assertEq(winner, alice);
            assertEq(weight, 10e18);
        }
        (address live,) = picker.pick(10e18);
        assertEq(live, bob);
    }

    function test_pickAtBeforeAnyDepositIsEmpty() public {
        _depositTrio();
        (address winner, uint256 weight) = picker.pickAt(99, 12345);
        assertEq(winner, address(0));
        assertEq(weight, 0);
    }

    function test_snapshotBlockMustFitThirtyTwoBits() public {
        _depositTrio();
        vm.expectRevert(HolderWeightedPicker.BlockTooLarge.selector);
        picker.pickAt(uint256(type(uint32).max) + 1, 1);
        (address winner,) = picker.pickAt(type(uint32).max, 50e18);
        assertEq(winner, carol);
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
