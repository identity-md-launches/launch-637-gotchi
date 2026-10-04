// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {LaunchToken} from "../../src/LaunchToken.sol";
import {HolderWeightedPicker} from "../../src/HolderWeightedPicker.sol";

/// @notice Moves GOTCHI between actors (including the excluded dead address and PoolManager), deposits,
/// withdraws, donates, rolls blocks and picks, at the current block and at past ones. The handler keeps
/// its own ledger of deposits (never read back from the picker), and a linear scan over that ledger is
/// the oracle for the block-checkpointed Fenwick tree.
contract PickerHandler is Test {
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;

    LaunchToken public token;
    HolderWeightedPicker public picker;
    address public poolManager;
    address[] public actors;

    // The handler's own ledger: holders in order of first deposit and what each has deposited.
    address[] public ghostHolders;
    mapping(address holder => bool) public ghostRegistered;
    mapping(address holder => uint256) public ghostWeight;
    uint256 public ghostTotal;
    /// @dev GOTCHI pushed into the picker with a plain transfer: custody without weight.
    uint256 public ghostDonated;

    uint256 public ghostPicks;
    uint256 public ghostDeposits;
    uint256 public ghostWithdrawals;
    uint256 public ghostFlashDeposits;
    uint256 public ghostPastPicks;
    string[] public violations;

    // The ledger as it stood at the end of `blockNumber`, recorded when the handler leaves that block.
    struct Snapshot {
        uint256 blockNumber;
        uint256 total;
        uint256[] weights;
    }

    Snapshot[] internal snapshots;
    uint256 public immutable firstBlock;

    constructor(LaunchToken token_, HolderWeightedPicker picker_, address poolManager_) {
        token = token_;
        picker = picker_;
        poolManager = poolManager_;
        firstBlock = block.number;
        for (uint256 i = 0; i < 6; i++) {
            actors.push(makeAddr(string.concat("actor", vm.toString(i))));
        }
        // Excluded addresses take part as senders and receivers of tokens, never as depositors.
        actors.push(DEAD);
        actors.push(poolManager_);
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function ghostHolderCount() external view returns (uint256) {
        return ghostHolders.length;
    }

    function violationCount() external view returns (uint256) {
        return violations.length;
    }

    function snapshotCount() external view returns (uint256) {
        return snapshots.length;
    }

    function snapshotAt(uint256 i)
        external
        view
        returns (uint256 blockNumber, uint256 total, uint256[] memory weights)
    {
        Snapshot storage s = snapshots[i];
        return (s.blockNumber, s.total, s.weights);
    }

    // ---------------------------------------------------------------------------------------------
    // Token movement
    // ---------------------------------------------------------------------------------------------

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

    /// @dev A plain transfer into the picker gives nobody weight.
    function donate(uint256 fromSeed, uint256 amount) external {
        address from = actors[fromSeed % actors.length];
        uint256 balance = token.balanceOf(from);
        if (balance == 0) return;
        amount = bound(amount, 1, balance);
        uint256 totalBefore = picker.totalWeight();
        vm.prank(from);
        token.transfer(address(picker), amount);
        ghostDonated += amount;
        _check(picker.totalWeight() == totalBefore, "a plain transfer changed the total weight");
        _check(picker.weightOf(from) == ghostWeight[from], "a plain transfer changed the sender's weight");
    }

    function rollBlocks(uint256 n) external {
        _snapshot();
        vm.roll(block.number + bound(n, 1, 50));
    }

    // ---------------------------------------------------------------------------------------------
    // Deposits and withdrawals
    // ---------------------------------------------------------------------------------------------

    function deposit(uint256 actorSeed, uint256 amount) external {
        address a = actors[actorSeed % actors.length];
        uint256 balance = token.balanceOf(a);
        amount = bound(amount, 0, balance);
        bool expectOk = !picker.isExcluded(a) && amount > 0;
        uint256 countBefore = picker.holderCount();
        uint256 pastTotal = picker.totalWeightAt(block.number - 1);
        vm.startPrank(a);
        token.approve(address(picker), amount);
        try picker.deposit(amount) returns (uint256 received) {
            _check(expectOk, "deposit succeeded for an excluded address or a zero amount");
            _check(received == amount, "credited amount differs from the amount sent");
            if (!ghostRegistered[a]) {
                ghostRegistered[a] = true;
                ghostHolders.push(a);
                _check(picker.holderCount() == countBefore + 1, "a first deposit did not append a holder");
                _check(picker.holderAt(countBefore) == a, "holder not appended in order");
            } else {
                _check(picker.holderCount() == countBefore, "a repeat deposit appended a holder");
            }
            ghostWeight[a] += amount;
            ghostTotal += amount;
            ghostDeposits += 1;
            _check(picker.weightOf(a) == ghostWeight[a], "weight after deposit differs from the ledger");
            _check(token.balanceOf(a) == balance - amount, "deposit did not take the tokens");
            _check(picker.totalWeightAt(block.number - 1) == pastTotal, "deposit rewrote the previous block");
        } catch {
            _check(!expectOk, "deposit reverted for an eligible holder with funds");
            _check(picker.holderCount() == countBefore, "a failed deposit appended a holder");
        }
        vm.stopPrank();
    }

    function withdraw(uint256 actorSeed, uint256 amount) external {
        address a = actors[actorSeed % actors.length];
        uint256 weight = ghostWeight[a];
        // One past the weight is reachable on purpose: nobody takes out more than they put in.
        amount = bound(amount, 0, weight + 1);
        bool expectOk = amount > 0 && amount <= weight;
        uint256 balance = token.balanceOf(a);
        uint256 pastTotal = picker.totalWeightAt(block.number - 1);
        uint256 pastWeight = picker.weightOfAt(a, block.number - 1);
        vm.prank(a);
        try picker.withdraw(amount) {
            _check(expectOk, "withdraw succeeded for nothing or beyond the holder's deposits");
            ghostWeight[a] -= amount;
            ghostTotal -= amount;
            ghostWithdrawals += 1;
            _check(picker.weightOf(a) == ghostWeight[a], "weight after withdraw differs from the ledger");
            _check(token.balanceOf(a) == balance + amount, "withdraw did not return the tokens");
            _check(picker.isRegistered(a), "a withdrawal unregistered the holder");
            _check(picker.totalWeightAt(block.number - 1) == pastTotal, "withdraw rewrote the previous block's total");
            _check(picker.weightOfAt(a, block.number - 1) == pastWeight, "withdraw rewrote the previous block's weight");
        } catch {
            _check(!expectOk, "withdraw of deposited weight reverted");
            _check(token.balanceOf(a) == balance, "a failed withdraw moved tokens");
        }
    }

    /// @dev Deposit and withdraw inside one block (what a flash loan must do): the previous block's
    /// snapshot, which is what a flip requested in this block resolves against, is untouched.
    function flashDeposit(uint256 actorSeed, uint256 amount, uint256 randomness) external {
        address a = actors[actorSeed % 6];
        uint256 balance = token.balanceOf(a);
        if (balance == 0) return;
        amount = bound(amount, 1, balance);
        uint256 past = block.number - 1;
        (address winnerBefore, uint256 weightBefore) = picker.pickAt(past, randomness);
        uint256 pastTotal = picker.totalWeightAt(past);
        vm.startPrank(a);
        token.approve(address(picker), amount);
        picker.deposit(amount);
        if (!ghostRegistered[a]) {
            ghostRegistered[a] = true;
            ghostHolders.push(a);
        }
        (address winnerDuring, uint256 weightDuring) = picker.pickAt(past, randomness);
        picker.withdraw(amount);
        vm.stopPrank();
        (address winnerAfter, uint256 weightAfter) = picker.pickAt(past, randomness);
        _check(winnerDuring == winnerBefore && weightDuring == weightBefore, "a same-block deposit changed a past pick");
        _check(winnerAfter == winnerBefore && weightAfter == weightBefore, "a flash deposit changed a past pick");
        _check(picker.totalWeightAt(past) == pastTotal, "a flash deposit changed a past total");
        _check(picker.weightOf(a) == ghostWeight[a], "a flash deposit left weight behind");
        _check(token.balanceOf(a) == balance, "a flash deposit did not return the tokens");
        ghostFlashDeposits += 1;
    }

    // ---------------------------------------------------------------------------------------------
    // Picks
    // ---------------------------------------------------------------------------------------------

    function pick(uint256 randomness) external {
        (address winner, uint256 weight) = picker.pick(randomness);
        (address expectedWinner, uint256 expectedWeight) = oracle(randomness);
        _check(winner == expectedWinner, "pick disagrees with the linear-scan oracle");
        _check(weight == expectedWeight, "pick weight disagrees with the oracle");
        (address again, uint256 weightAgain) = picker.pick(randomness);
        _check(again == winner && weightAgain == weight, "pick is not deterministic");
        (address atBlock, uint256 weightAtBlock) = picker.pickAt(block.number, randomness);
        _check(atBlock == winner && weightAtBlock == weight, "pick differs from pickAt at the current block");
        if (winner != address(0)) {
            _check(!picker.isExcluded(winner), "winner is excluded");
            _check(weight > 0, "a zero-weight holder won");
        } else {
            _check(ghostTotal == 0, "nobody won although weight is deposited");
        }
        ghostPicks += 1;
    }

    /// @dev Picks at a block inside the span a recorded snapshot covers and checks it against the ledger
    /// as it stood then.
    function pickAtPastBlock(uint256 snapshotSeed, uint256 blockSeed, uint256 randomness) external {
        uint256 n = snapshots.length;
        if (n == 0) return;
        uint256 i = snapshotSeed % n;
        // Nothing changes between leaving a block and the next block the handler acts in.
        uint256 lastCovered = (i + 1 < n ? snapshots[i + 1].blockNumber : block.number) - 1;
        uint256 b = bound(blockSeed, snapshots[i].blockNumber, lastCovered);
        (address winner, uint256 weight) = picker.pickAt(b, randomness);
        (address expectedWinner, uint256 expectedWeight) = oracleAtSnapshot(i, randomness);
        _check(winner == expectedWinner, "pickAt at a past block disagrees with the ledger of that block");
        _check(weight == expectedWeight, "pickAt weight at a past block disagrees with the ledger of that block");
        _check(picker.totalWeightAt(b) == snapshots[i].total, "totalWeightAt differs from the ledger of that block");
        ghostPastPicks += 1;
    }

    /// @dev Independent selection against the handler's current ledger.
    function oracle(uint256 randomness) public view returns (address, uint256) {
        if (ghostTotal == 0) return (address(0), 0);
        uint256 target = randomness % ghostTotal;
        uint256 cumulative = 0;
        for (uint256 i = 0; i < ghostHolders.length; i++) {
            uint256 w = ghostWeight[ghostHolders[i]];
            if (target < cumulative + w) return (ghostHolders[i], w);
            cumulative += w;
        }
        revert("oracle: target beyond total");
    }

    /// @dev Independent selection against the ledger recorded in snapshot `i`.
    function oracleAtSnapshot(uint256 i, uint256 randomness) public view returns (address, uint256) {
        Snapshot storage s = snapshots[i];
        if (s.total == 0) return (address(0), 0);
        uint256 target = randomness % s.total;
        uint256 cumulative = 0;
        for (uint256 j = 0; j < s.weights.length; j++) {
            uint256 w = s.weights[j];
            if (target < cumulative + w) return (ghostHolders[j], w);
            cumulative += w;
        }
        revert("oracle: target beyond total");
    }

    function _snapshot() private {
        Snapshot storage s = snapshots.push();
        s.blockNumber = block.number;
        s.total = ghostTotal;
        for (uint256 i = 0; i < ghostHolders.length; i++) {
            s.weights.push(ghostWeight[ghostHolders[i]]);
        }
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
        vm.roll(100);
        token = new LaunchToken();
        picker = new HolderWeightedPicker(address(token), poolManager);
        handler = new PickerHandler(token, picker, poolManager);
        token.transfer(address(handler), token.totalSupply());
        // Every actor starts with a balance so deposits are reachable from the first call.
        for (uint256 i = 0; i < handler.actorCount(); i++) {
            handler.give(i, 1_000e18);
        }
        targetContract(address(handler));
    }

    /// @dev Conservation: the picker holds what it owes its depositors, plus only what was donated to it.
    function invariant_custodyEqualsDepositsPlusDonations() public view {
        assertEq(
            token.balanceOf(address(picker)),
            picker.totalWeight() + handler.ghostDonated(),
            "custody differs from deposited weight plus donations"
        );
        assertEq(picker.totalWeight(), handler.ghostTotal(), "totalWeight differs from deposits minus withdrawals");
    }

    function invariant_storedWeightsMatchTheLedger() public view {
        uint256 sum = 0;
        uint256 n = picker.holderCount();
        assertEq(n, handler.ghostHolderCount(), "holder count differs from the ledger");
        for (uint256 i = 0; i < n; i++) {
            address h = picker.holderAt(i);
            assertEq(h, handler.ghostHolders(i), "holder order differs from the ledger");
            assertEq(picker.weightOf(h), handler.ghostWeight(h), "a stored weight differs from the ledger");
            sum += picker.weightOf(h);
        }
        assertEq(picker.totalWeight(), sum, "totalWeight equals the sum of stored weights");
    }

    function invariant_fenwickPrefixSumsMatchTheHolderList() public view {
        uint256 n = picker.holderCount();
        uint256 running = 0;
        for (uint256 i = 0; i < n; i++) {
            running += handler.ghostWeight(picker.holderAt(i));
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
        assertEq(picker.weightOf(DEAD) + picker.weightOf(poolManager) + picker.weightOf(address(picker)), 0);
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
        uint256 total = handler.ghostTotal();
        uint256[5] memory samples = [uint256(0), 1, total / 3, total == 0 ? 0 : total - 1, type(uint256).max];
        for (uint256 i = 0; i < samples.length; i++) {
            (address winner, uint256 weight) = picker.pick(samples[i]);
            (address expected, uint256 expectedWeight) = handler.oracle(samples[i]);
            assertEq(winner, expected, "pick differs from the oracle");
            assertEq(weight, expectedWeight, "pick weight differs from the oracle");
            if (winner != address(0)) {
                assertGt(weight, 0, "a zero-weight holder won");
                assertTrue(winner != DEAD && winner != poolManager, "an excluded address won");
            }
        }
        if (total == 0) {
            (address none,) = picker.pick(12_345);
            assertEq(none, address(0), "nobody can win with zero total weight");
        }
    }

    /// @dev What the registry held at the end of a block is what it reports for that block forever: later
    /// deposits and withdrawals never rewrite a snapshot the escrow may have frozen a flip to.
    function invariant_pastBlocksNeverChange() public view {
        uint256 n = handler.snapshotCount();
        for (uint256 i = 0; i < n; i++) {
            (uint256 b, uint256 total, uint256[] memory weights) = handler.snapshotAt(i);
            assertLt(b, block.number, "a snapshot block is not in the past");
            assertEq(picker.totalWeightAt(b), total, "a past block's total changed");
            assertEq(picker.holderCountAt(b), weights.length, "a past block's holder count changed");
            for (uint256 j = 0; j < weights.length; j++) {
                assertEq(picker.weightOfAt(picker.holderAt(j), b), weights[j], "a past block's holder weight changed");
            }
            for (uint256 j = weights.length; j < picker.holderCount(); j++) {
                assertEq(picker.weightOfAt(picker.holderAt(j), b), 0, "a later holder has weight in an earlier block");
            }
            (address winner, uint256 weight) = picker.pickAt(b, uint256(keccak256(abi.encode(i, b))));
            (address expected, uint256 expectedWeight) =
                handler.oracleAtSnapshot(i, uint256(keccak256(abi.encode(i, b))));
            assertEq(winner, expected, "a past block's pick changed");
            assertEq(weight, expectedWeight, "a past block's pick weight changed");
        }
        uint256 beforeAnything = handler.firstBlock() - 1;
        assertEq(picker.totalWeightAt(beforeAnything), 0, "the registry is empty before its first block");
        assertEq(picker.holderCountAt(beforeAnything), 0, "no holders before the first block");
        assertEq(picker.totalWeightAt(block.number), picker.totalWeight(), "the current block is the live total");
        assertEq(picker.holderCountAt(block.number), picker.holderCount(), "the current block is the live count");
    }

    function invariant_supplyIsConserved() public view {
        uint256 sum = token.balanceOf(address(handler)) + token.balanceOf(address(picker));
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
        emit log_named_uint("deposits", handler.ghostDeposits());
        emit log_named_uint("withdrawals", handler.ghostWithdrawals());
        emit log_named_uint("flash deposits", handler.ghostFlashDeposits());
        emit log_named_uint("picks", handler.ghostPicks());
        emit log_named_uint("picks at past blocks", handler.ghostPastPicks());
        emit log_named_uint("snapshots", handler.snapshotCount());
    }
}
