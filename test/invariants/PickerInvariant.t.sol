// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {LaunchToken} from "../../src/LaunchToken.sol";
import {HolderWeightedPicker} from "../../src/HolderWeightedPicker.sol";

/// @notice Moves GOTCHI between actors (including the excluded dead address and PoolManager), registers,
/// refreshes and picks. A linear scan over the stored weights is the oracle for the Fenwick tree.
contract PickerHandler is Test {
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;

    LaunchToken public token;
    HolderWeightedPicker public picker;
    address public poolManager;
    address[] public actors;

    uint256 public ghostPicks;
    uint256 public ghostForfeits;
    uint256 public ghostRegistrations;
    string[] public violations;

    constructor(LaunchToken token_, HolderWeightedPicker picker_, address poolManager_) {
        token = token_;
        picker = picker_;
        poolManager = poolManager_;
        for (uint256 i = 0; i < 6; i++) {
            actors.push(makeAddr(string.concat("actor", vm.toString(i))));
        }
        // Excluded addresses take part as senders and receivers of tokens, never as registrants.
        actors.push(DEAD);
        actors.push(poolManager_);
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function violationCount() external view returns (uint256) {
        return violations.length;
    }

    function give(uint256 toSeed, uint256 amount) external {
        address to = actors[toSeed % actors.length];
        uint256 balance = token.balanceOf(address(this));
        if (balance == 0) return;
        token.transfer(to, bound(amount, 1, balance < 1_000e18 ? balance : 1_000e18));
    }

    function move(uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        address from = actors[fromSeed % actors.length];
        address to = actors[toSeed % actors.length];
        uint256 balance = token.balanceOf(from);
        if (balance == 0) return;
        vm.prank(from);
        token.transfer(to, bound(amount, 1, balance));
    }

    function register(uint256 actorSeed) external {
        address a = actors[actorSeed % actors.length];
        bool expectOk = !picker.isExcluded(a) && !picker.isRegistered(a) && token.balanceOf(a) > 0;
        uint256 totalBefore = picker.totalWeight();
        uint256 countBefore = picker.holderCount();
        vm.prank(a);
        try picker.register() {
            _check(expectOk, "register succeeded for an ineligible address");
            _check(picker.weightOf(a) == token.balanceOf(a), "registered weight is not the balance");
            _check(picker.totalWeight() == totalBefore + token.balanceOf(a), "totalWeight did not grow by the weight");
            _check(picker.holderCount() == countBefore + 1, "holder count did not grow");
            _check(picker.holderAt(countBefore) == a, "holder not appended in order");
            ghostRegistrations += 1;
        } catch {
            _check(!expectOk, "register reverted for an eligible holder");
            _check(
                picker.totalWeight() == totalBefore && picker.holderCount() == countBefore,
                "failed register changed state"
            );
        }
    }

    function refresh(uint256 actorSeed) external {
        address a = actors[actorSeed % actors.length];
        bool registered = picker.isRegistered(a);
        uint256 oldWeight = picker.weightOf(a);
        uint256 totalBefore = picker.totalWeight();
        try picker.refresh(a) {
            _check(registered, "refreshed an unregistered address");
            uint256 live = token.balanceOf(a);
            _check(picker.weightOf(a) == live, "refreshed weight is not the live balance");
            _check(picker.totalWeight() == totalBefore - oldWeight + live, "totalWeight did not move by the difference");
        } catch {
            _check(!registered, "refresh reverted for a registered holder");
        }
    }

    function pick(uint256 randomness) external {
        (address winner, uint256 weight) = picker.pick(randomness);
        (address expectedWinner, uint256 expectedWeight) = oracle(randomness);
        _check(winner == expectedWinner, "pick disagrees with the linear-scan oracle");
        _check(weight == expectedWeight, "pick weight disagrees with the oracle");
        (address again, uint256 weightAgain) = picker.pick(randomness);
        _check(again == winner && weightAgain == weight, "pick is not deterministic");
        if (winner != address(0)) {
            _check(picker.isRegistered(winner), "winner is not registered");
            _check(!picker.isExcluded(winner), "winner is excluded");
            _check(weight > 0 && weight == picker.weightOf(winner), "winner weight is not their stored weight");
            _check(token.balanceOf(winner) >= weight, "winner's live balance is below the stored weight");
        } else if (picker.totalWeight() > 0) {
            ghostForfeits += 1;
        }
        ghostPicks += 1;
    }

    /// @dev Independent selection: walk the holders in registration order and find the first whose
    /// cumulative weight range contains the target; then apply the live-balance rule.
    function oracle(uint256 randomness) public view returns (address, uint256) {
        uint256 total = picker.totalWeight();
        if (total == 0) return (address(0), 0);
        uint256 target = randomness % total;
        uint256 cumulative = 0;
        uint256 n = picker.holderCount();
        for (uint256 i = 0; i < n; i++) {
            address h = picker.holderAt(i);
            uint256 w = picker.weightOf(h);
            if (target < cumulative + w) {
                if (token.balanceOf(h) < w) return (address(0), 0);
                return (h, w);
            }
            cumulative += w;
        }
        revert("oracle: target beyond total");
    }

    function _check(bool condition, string memory what) private {
        if (!condition) violations.push(what);
    }
}

/// forge-config: default.invariant.runs = 128
/// forge-config: default.invariant.depth = 60
contract PickerInvariantTest is StdInvariant, Test {
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;

    LaunchToken token;
    HolderWeightedPicker picker;
    PickerHandler handler;
    address poolManager = makeAddr("poolManager");

    function setUp() public {
        token = new LaunchToken();
        picker = new HolderWeightedPicker(address(token), poolManager);
        handler = new PickerHandler(token, picker, poolManager);
        token.transfer(address(handler), token.totalSupply());
        targetContract(address(handler));
    }

    function invariant_totalWeightIsTheSumOfStoredWeights() public view {
        uint256 sum = 0;
        uint256 n = picker.holderCount();
        for (uint256 i = 0; i < n; i++) {
            sum += picker.weightOf(picker.holderAt(i));
        }
        assertEq(picker.totalWeight(), sum, "totalWeight equals the sum of stored weights");
    }

    function invariant_fenwickPrefixSumsMatchTheHolderList() public view {
        uint256 n = picker.holderCount();
        uint256 running = 0;
        for (uint256 i = 0; i < n; i++) {
            running += picker.weightOf(picker.holderAt(i));
            assertEq(picker.prefixWeight(i + 1), running, "prefix sum differs from the holder weights");
        }
        assertEq(picker.prefixWeight(n), picker.totalWeight(), "full prefix equals totalWeight");
        assertEq(picker.prefixWeight(0), 0, "empty prefix is zero");
    }

    function invariant_excludedAddressesAreNeverRegistered() public view {
        assertFalse(picker.isRegistered(DEAD), "dead address registered");
        assertFalse(picker.isRegistered(poolManager), "pool manager registered");
        assertFalse(picker.isRegistered(address(0)), "zero address registered");
        assertFalse(picker.isRegistered(address(picker)), "picker registered itself");
        uint256 n = picker.holderCount();
        for (uint256 i = 0; i < n; i++) {
            address h = picker.holderAt(i);
            assertFalse(picker.isExcluded(h), "an excluded address is in the holder list");
            assertTrue(picker.isRegistered(h), "a listed holder is not registered");
            for (uint256 j = i + 1; j < n; j++) {
                assertTrue(picker.holderAt(j) != h, "a holder is listed twice");
            }
        }
        assertLe(n, picker.CAPACITY(), "capacity respected");
    }

    function invariant_pickMatchesTheOracleAcrossTheRange() public view {
        uint256 total = picker.totalWeight();
        uint256[5] memory samples = [uint256(0), 1, total / 3, total == 0 ? 0 : total - 1, type(uint256).max];
        for (uint256 i = 0; i < samples.length; i++) {
            (address winner, uint256 weight) = picker.pick(samples[i]);
            (address expected, uint256 expectedWeight) = handler.oracle(samples[i]);
            assertEq(winner, expected, "pick differs from the oracle");
            assertEq(weight, expectedWeight, "pick weight differs from the oracle");
            if (winner != address(0)) {
                assertGt(weight, 0, "a zero-weight holder won");
                assertGe(token.balanceOf(winner), weight, "winner's live balance below stored weight");
            }
        }
        if (total == 0) {
            (address none,) = picker.pick(12_345);
            assertEq(none, address(0), "nobody can win with zero total weight");
        }
    }

    function invariant_supplyIsConserved() public view {
        uint256 sum = token.balanceOf(address(handler));
        for (uint256 i = 0; i < handler.actorCount(); i++) {
            sum += token.balanceOf(handler.actors(i));
        }
        assertEq(sum, token.totalSupply(), "tokens went missing");
    }

    function invariant_noViolations() public {
        uint256 n = handler.violationCount();
        if (n > 0) emit log_named_string("first violation", handler.violations(0));
        assertEq(n, 0, "a handler expectation failed; see the logged violation");
    }

    function afterInvariant() public {
        emit log_named_uint("registrations", handler.ghostRegistrations());
        emit log_named_uint("picks", handler.ghostPicks());
        emit log_named_uint("forfeits", handler.ghostForfeits());
    }
}
