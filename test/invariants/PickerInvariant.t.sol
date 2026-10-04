// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {LaunchToken} from "../../src/LaunchToken.sol";
import {HolderWeightedPicker} from "../../src/HolderWeightedPicker.sol";

/// @notice Moves GOTCHI between actors (including the excluded dead address and PoolManager), registers,
/// refreshes, picks and draws, at the current version and at past ones. A linear scan over the
/// checkpointed weights is the oracle for the versioned Fenwick tree, re-draws included.
contract PickerHandler is Test {
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;

    LaunchToken public token;
    HolderWeightedPicker public picker;
    address public poolManager;
    address[] public actors;

    uint256 public ghostPicks;
    uint256 public ghostForfeits;
    uint256 public ghostRegistrations;
    uint256 public ghostDraws;
    uint256 public ghostDrawRefreshes;
    uint256 public ghostOldVersionPicks;
    /// @dev Every version bump the handler caused: one per registration, one per refresh that changed a
    /// weight, and one per stale holder a `drawAt` refreshed.
    uint256 public ghostVersionBumps;
    string[] public violations;

    // What the registry reported at a version right after the mutation that created it; must never change.
    struct Snapshot {
        uint256 version;
        uint256 total;
        uint256 count;
        address holder;
        uint256 holderWeight;
    }

    Snapshot[] public snapshots;

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

    function snapshotCount() external view returns (uint256) {
        return snapshots.length;
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
        uint256 versionBefore = picker.version();
        vm.prank(a);
        try picker.register() {
            _check(expectOk, "register succeeded for an ineligible address");
            _check(picker.weightOf(a) == token.balanceOf(a), "registered weight is not the balance");
            _check(picker.totalWeight() == totalBefore + token.balanceOf(a), "totalWeight did not grow by the weight");
            _check(picker.holderCount() == countBefore + 1, "holder count did not grow");
            _check(picker.holderAt(countBefore) == a, "holder not appended in order");
            _check(picker.version() == versionBefore + 1, "register did not bump the version by one");
            _check(picker.weightOfAt(a, versionBefore) == 0, "the new holder has weight before their registration");
            _check(picker.holderCountAt(versionBefore) == countBefore, "registration leaked into the previous version");
            ghostRegistrations += 1;
            ghostVersionBumps += 1;
            _snapshot(a);
        } catch {
            _check(!expectOk, "register reverted for an eligible holder");
            _check(
                picker.totalWeight() == totalBefore && picker.holderCount() == countBefore
                    && picker.version() == versionBefore,
                "failed register changed state"
            );
        }
    }

    function refresh(uint256 actorSeed) external {
        address a = actors[actorSeed % actors.length];
        bool registered = picker.isRegistered(a);
        uint256 oldWeight = picker.weightOf(a);
        uint256 totalBefore = picker.totalWeight();
        uint256 versionBefore = picker.version();
        try picker.refresh(a) {
            _check(registered, "refreshed an unregistered address");
            uint256 live = token.balanceOf(a);
            _check(picker.weightOf(a) == live, "refreshed weight is not the live balance");
            _check(picker.totalWeight() == totalBefore - oldWeight + live, "totalWeight did not move by the difference");
            if (live == oldWeight) {
                _check(picker.version() == versionBefore, "an unchanged weight bumped the version");
            } else {
                _check(picker.version() == versionBefore + 1, "a changed weight did not bump the version by one");
                _check(picker.weightOfAt(a, versionBefore) == oldWeight, "refresh rewrote the previous version");
                ghostVersionBumps += 1;
                _snapshot(a);
            }
        } catch {
            _check(!registered, "refresh reverted for a registered holder");
            _check(picker.version() == versionBefore, "a failed refresh bumped the version");
        }
    }

    function pick(uint256 randomness) external {
        (address winner, uint256 weight) = picker.pick(randomness);
        (address expectedWinner, uint256 expectedWeight) = oracle(randomness);
        _check(winner == expectedWinner, "pick disagrees with the linear-scan oracle");
        _check(weight == expectedWeight, "pick weight disagrees with the oracle");
        (address again, uint256 weightAgain) = picker.pick(randomness);
        _check(again == winner && weightAgain == weight, "pick is not deterministic");
        (address atVersion, uint256 weightAtVersion) = picker.pickAt(picker.version(), randomness);
        _check(atVersion == winner && weightAtVersion == weight, "pick differs from pickAt at the current version");
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

    /// @dev `drawAt` at the current version must answer exactly like `pickAt`, and its only side effect is
    /// refreshing stale holders it landed on: every version bump it causes is one more holder whose
    /// stored weight now equals their live balance, and nothing older changes.
    function draw(uint256 randomness) external {
        uint256 v = picker.version();
        (address expectedWinner, uint256 expectedWeight) = picker.pickAt(v, randomness);
        (address oracleWinner, uint256 oracleWeight) = oracleAt(v, randomness);
        uint256 totalBefore = picker.totalWeight();
        (address winner, uint256 weight) = picker.drawAt(v, randomness);
        _check(winner == expectedWinner && weight == expectedWeight, "drawAt disagrees with pickAt");
        _check(winner == oracleWinner && weight == oracleWeight, "drawAt disagrees with the oracle");
        uint256 bumps = picker.version() - v;
        ghostVersionBumps += bumps;
        ghostDrawRefreshes += bumps;
        _check(picker.totalWeightAt(v) == totalBefore, "drawAt rewrote the version it drew against");
        if (winner != address(0)) {
            _check(picker.weightOfAt(winner, v) == weight, "winner's weight is not their snapshot weight");
            _check(token.balanceOf(winner) >= weight, "winner's live balance is below the snapshot weight");
        }
        if (bumps == 0) {
            _check(picker.totalWeight() == totalBefore, "drawAt changed totals without a version bump");
        } else {
            _check(picker.totalWeight() < totalBefore, "a refresh during drawAt did not lower the total");
        }
        ghostDraws += 1;
    }

    /// @dev Picks against a past version and checks it against the oracle computed from the checkpoints.
    function pickAtOldVersion(uint256 versionSeed, uint256 randomness) external {
        uint256 v = bound(versionSeed, 0, picker.version());
        (address winner, uint256 weight) = picker.pickAt(v, randomness);
        (address expectedWinner, uint256 expectedWeight) = oracleAt(v, randomness);
        _check(winner == expectedWinner, "pickAt at a past version disagrees with the oracle");
        _check(weight == expectedWeight, "pickAt weight at a past version disagrees with the oracle");
        if (winner != address(0)) {
            _check(picker.weightOfAt(winner, v) == weight, "past winner's weight is not their weight then");
            _check(token.balanceOf(winner) >= weight, "past winner's live balance is below that weight");
        }
        ghostOldVersionPicks += 1;
    }

    /// @dev Independent selection against the current version.
    function oracle(uint256 randomness) public view returns (address, uint256) {
        return oracleAt(picker.version(), randomness);
    }

    /// @dev Independent selection against version `v`: for each of `MAX_DRAWS` deterministic rolls, walk
    /// the holders registered by then in registration order and find the first whose cumulative weight
    /// range (weights as of `v`) contains the target; the first such holder whose live balance still
    /// covers that weight wins. If every draw lands on a stale holder nobody wins.
    function oracleAt(uint256 v, uint256 randomness) public view returns (address, uint256) {
        uint256 total = picker.totalWeightAt(v);
        if (total == 0) return (address(0), 0);
        uint256 n = picker.holderCountAt(v);
        uint256 maxDraws = picker.MAX_DRAWS();
        for (uint256 attempt = 0; attempt < maxDraws; attempt++) {
            uint256 roll = attempt == 0 ? randomness : uint256(keccak256(abi.encode(randomness, attempt)));
            (address h, uint256 w) = _scan(v, roll % total, n);
            if (token.balanceOf(h) >= w) return (h, w);
        }
        return (address(0), 0);
    }

    function _scan(uint256 v, uint256 target, uint256 n) private view returns (address, uint256) {
        uint256 cumulative = 0;
        for (uint256 i = 0; i < n; i++) {
            address h = picker.holderAt(i);
            uint256 w = picker.weightOfAt(h, v);
            if (target < cumulative + w) return (h, w);
            cumulative += w;
        }
        revert("oracle: target beyond total");
    }

    function _snapshot(address holder) private {
        uint256 v = picker.version();
        snapshots.push(
            Snapshot({
                version: v,
                total: picker.totalWeightAt(v),
                count: picker.holderCountAt(v),
                holder: holder,
                holderWeight: picker.weightOfAt(holder, v)
            })
        );
        _check(picker.totalWeightAt(v) == picker.totalWeight(), "latest version total differs from totalWeight");
        _check(picker.holderCountAt(v) == picker.holderCount(), "latest version count differs from holderCount");
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

    /// @dev What a version reported when it was created is what it reports forever: later registrations,
    /// refreshes and draws may only add versions, never rewrite one the escrow may have frozen a flip to.
    function invariant_pastVersionsNeverChange() public view {
        uint256 n = handler.snapshotCount();
        for (uint256 i = 0; i < n; i++) {
            (uint256 v, uint256 total, uint256 count, address holder, uint256 holderWeight) = handler.snapshots(i);
            assertEq(picker.totalWeightAt(v), total, "a past version's total changed");
            assertEq(picker.holderCountAt(v), count, "a past version's holder count changed");
            assertEq(picker.weightOfAt(holder, v), holderWeight, "a past version's holder weight changed");
            assertLe(v, picker.version(), "a snapshot version is ahead of the current one");
        }
        assertEq(picker.totalWeightAt(0), 0, "version zero is empty");
        assertEq(picker.holderCountAt(0), 0, "version zero has no holders");
        assertEq(picker.totalWeightAt(picker.version()), picker.totalWeight(), "latest version is the live total");
        assertEq(picker.holderCountAt(picker.version()), picker.holderCount(), "latest version is the live count");
    }

    function invariant_versionCountsEveryMutation() public view {
        assertEq(picker.version(), handler.ghostVersionBumps(), "version moved by something other than a mutation");
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
        emit log_named_uint("draws", handler.ghostDraws());
        emit log_named_uint("stale holders refreshed by draws", handler.ghostDrawRefreshes());
        emit log_named_uint("picks at past versions", handler.ghostOldVersionPicks());
        emit log_named_uint("versions", picker.version());
    }
}
