// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Checkpoints} from "@openzeppelin/contracts/utils/structs/Checkpoints.sol";

/// @title HolderWeightedPicker
/// @notice Deterministically selects a $GOTCHI holder with probability proportional to balance, against
/// a versioned snapshot of the registry so that nothing done after a flip was requested can change who
/// wins it.
///
/// @dev Weighting model ("versioned snapshot with live confirmation"):
///  - Holders opt in with `register()` (only for themselves, so contracts that merely hold tokens, such
///    as a distributor, are never entered by a third party). Registration records the holder's current
///    balance as their weight.
///  - `refresh(holder)` may be called by anyone, any time, and re-reads that holder's balance. Weights
///    are therefore a snapshot as of each holder's last refresh, not a live view. A UI or keeper should
///    refresh registered holders before a purchase binds a flip.
///  - Every mutation (`register`, `refresh`) increments `version` and checkpoints the affected Fenwick
///    tree nodes, the holder's weight and the totals under that version (OpenZeppelin `Checkpoints`).
///    `pickAt(version, randomness)` answers against the registry exactly as it stood at that version;
///    the FlipEscrow records `version()` when it binds a flip and resolves it with `pickAt`, so a
///    registration or refresh made once the roll is knowable (the reveal is in the mempool) cannot
///    steer the result. `pick(randomness)` is the same against the current version.
///  - Selection walks the Fenwick tree in O(log n) and returns the holder whose cumulative range contains
///    `randomness mod totalWeight`. It then reads that holder's *live* balance once: if it is below the
///    stored weight (tokens moved since the last refresh) the draw forfeits and up to `MAX_DRAWS - 1`
///    deterministic re-draws (`keccak256(randomness, i)`) follow; only when every draw forfeits does it
///    return the zero address, which the escrow treats as a burn. This stops a holder from inflating
///    their odds by refreshing a balance and then moving the tokens elsewhere. `drawAt` (what the escrow
///    calls) additionally refreshes every stale holder it lands on, so entries backed by tokens that have
///    moved on (one bag registered through several wallets) lose their weight for all later flips instead
///    of turning honest holders' airdrops into burns indefinitely.
///  - Excluded, permanently: the zero address, the dead/burn address, the PoolManager (it holds the
///    pool's tokens) and this contract. Zero balances carry zero weight and can never be selected.
///  - The tree is append-only and unbounded: there is no registration cap to fill.
///
/// There is no admin role: the exclusion list is fixed in the constructor and nobody can edit weights.
contract HolderWeightedPicker {
    using Checkpoints for Checkpoints.Trace224;

    /// @notice Conventional burn address, never eligible.
    address public constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;
    /// @notice Draws attempted per pick before giving up (first draw plus re-draws on stale weights).
    uint256 public constant MAX_DRAWS = 8;

    /// @notice The token whose balances are the weights.
    IERC20 public immutable TOKEN;
    /// @notice The Uniswap v4 PoolManager, excluded because it custodies the pool's tokens.
    address public immutable EXCLUDED_POOL_MANAGER;

    /// @notice Sum of all stored weights (current version).
    uint256 public totalWeight;
    /// @notice Incremented by every `register` and `refresh`; the key `pickAt` snapshots are taken under.
    uint256 public version;

    address[] private _holders;
    // 1-based position in `_holders` (0 = not registered).
    mapping(address holder => uint256 position) private _positionOf;
    // Weight history per holder, keyed by version.
    mapping(address holder => Checkpoints.Trace224 history) private _weightHistory;
    // Fenwick tree over positions 1..n with a checkpoint history per node, keyed by version.
    mapping(uint256 node => Checkpoints.Trace224 history) private _tree;
    // (holder count << 192 | total weight) per version.
    Checkpoints.Trace224 private _totals;

    /// @notice A holder opted in with their current balance as weight.
    event HolderRegistered(address indexed holder, uint256 weight);
    /// @notice A registered holder's weight was re-read from the token.
    event WeightRefreshed(address indexed holder, uint256 oldWeight, uint256 newWeight);

    error ZeroAddress();
    error Excluded(address holder);
    error AlreadyRegistered(address holder);
    error NotRegistered(address holder);
    error ZeroBalance(address holder);
    error VersionTooLarge();

    constructor(address token, address poolManager) {
        if (token == address(0) || poolManager == address(0)) revert ZeroAddress();
        TOKEN = IERC20(token);
        EXCLUDED_POOL_MANAGER = poolManager;
    }

    // ---------------------------------------------------------------------------------------------
    // Registration
    // ---------------------------------------------------------------------------------------------

    /// @notice Opts the caller into airdrops with their current balance as weight.
    function register() external {
        address holder = msg.sender;
        if (isExcluded(holder)) revert Excluded(holder);
        if (_positionOf[holder] > 0) revert AlreadyRegistered(holder);
        uint256 weight = TOKEN.balanceOf(holder);
        if (weight < 1) revert ZeroBalance(holder);

        uint32 v = _bump();
        _holders.push(holder);
        uint256 position = _holders.length;
        _positionOf[holder] = position;
        // Appending element `position` creates exactly one new Fenwick node, covering
        // (position - lowbit(position), position]. Existing nodes never cover a later position.
        uint256 lowbit = position & (~position + 1);
        uint256 nodeSum = weight + _prefixLatest(position - 1) - _prefixLatest(position - lowbit);
        _tree[position].push(v, _toUint224(nodeSum));
        _weightHistory[holder].push(v, _toUint224(weight));
        totalWeight += weight;
        _pushTotals(v, position);
        emit HolderRegistered(holder, weight);
    }

    /// @notice Re-reads `holder`'s balance into their weight. Anyone may call it for any registered holder.
    function refresh(address holder) external {
        if (_positionOf[holder] < 1) revert NotRegistered(holder);
        _refresh(holder);
    }

    function _refresh(address holder) private {
        uint256 position = _positionOf[holder];
        uint256 oldWeight = _weightHistory[holder].latest();
        uint256 newWeight = TOKEN.balanceOf(holder);
        emit WeightRefreshed(holder, oldWeight, newWeight);
        if (newWeight == oldWeight) return; // nothing to checkpoint
        uint32 v = _bump();
        _weightHistory[holder].push(v, _toUint224(newWeight));
        if (newWeight > oldWeight) {
            uint256 diff = newWeight - oldWeight;
            totalWeight += diff;
            _apply(position, v, diff, true);
        } else {
            uint256 diff = oldWeight - newWeight;
            totalWeight -= diff;
            _apply(position, v, diff, false);
        }
        _pushTotals(v, _holders.length);
    }

    // ---------------------------------------------------------------------------------------------
    // Selection
    // ---------------------------------------------------------------------------------------------

    /// @notice Picks against the current version; see `pickAt`.
    function pick(uint256 randomness) external view returns (address winner, uint256 weight) {
        return pickAt(version, randomness);
    }

    /// @notice Picks the holder whose weight range, as of `snapshotVersion`, contains
    /// `randomness % totalWeight(snapshotVersion)`, re-drawing up to `MAX_DRAWS` times when the selected
    /// holder's live balance fell below their snapshot weight.
    /// @return winner The selected holder, or the zero address when nobody was eligible at that version
    /// or every draw forfeited.
    /// @return weight The snapshot weight the winner was selected with (0 when `winner` is zero).
    function pickAt(uint256 snapshotVersion, uint256 randomness) public view returns (address winner, uint256 weight) {
        uint32 v = _toUint32(snapshotVersion);
        (uint256 count, uint256 total) = _totalsAt(v);
        if (total < 1) return (address(0), 0);
        for (uint256 draw = 0; draw < MAX_DRAWS; draw++) {
            (address candidate, uint256 stored, bool eligible) = _candidate(v, count, total, randomness, draw);
            if (eligible) return (candidate, stored);
        }
        return (address(0), 0);
    }

    /// @notice `pickAt`, plus housekeeping: every stale holder a draw lands on is refreshed to their live
    /// balance (under a new version, so no earlier snapshot changes), which strips abandoned or sybil
    /// entries of their weight for every later flip. Anyone may call it; it only performs refreshes anyone
    /// could have performed. The FlipEscrow resolves flips through it.
    function drawAt(uint256 snapshotVersion, uint256 randomness) external returns (address winner, uint256 weight) {
        uint32 v = _toUint32(snapshotVersion);
        (uint256 count, uint256 total) = _totalsAt(v);
        if (total < 1) return (address(0), 0);
        for (uint256 draw = 0; draw < MAX_DRAWS; draw++) {
            (address candidate, uint256 stored, bool eligible) = _candidate(v, count, total, randomness, draw);
            if (eligible) return (candidate, stored);
            _refresh(candidate);
        }
        return (address(0), 0);
    }

    /// @dev The holder draw number `draw` selects at version `v`, their snapshot weight, and whether their
    /// live balance still covers it.
    function _candidate(uint32 v, uint256 count, uint256 total, uint256 randomness, uint256 draw)
        private
        view
        returns (address candidate, uint256 stored, bool eligible)
    {
        uint256 roll = draw == 0 ? randomness : uint256(keccak256(abi.encode(randomness, draw)));
        uint256 position = _select(roll % total, count, v);
        candidate = _holders[position - 1];
        stored = _weightHistory[candidate].upperLookup(v);
        eligible = TOKEN.balanceOf(candidate) >= stored;
    }

    // ---------------------------------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------------------------------

    /// @notice Whether `holder` can never be registered.
    function isExcluded(address holder) public view returns (bool) {
        return
            holder == address(0) || holder == BURN_ADDRESS || holder == EXCLUDED_POOL_MANAGER || holder == address(this);
    }

    /// @notice Whether `holder` has registered.
    function isRegistered(address holder) external view returns (bool) {
        return _positionOf[holder] > 0;
    }

    /// @notice The stored (last refreshed) weight of `holder`; 0 when unregistered.
    function weightOf(address holder) external view returns (uint256) {
        return _weightHistory[holder].latest();
    }

    /// @notice The weight `holder` had as of `snapshotVersion`; 0 when not registered by then.
    function weightOfAt(address holder, uint256 snapshotVersion) external view returns (uint256) {
        return _weightHistory[holder].upperLookup(_toUint32(snapshotVersion));
    }

    /// @notice The total stored weight as of `snapshotVersion`.
    function totalWeightAt(uint256 snapshotVersion) external view returns (uint256 total) {
        (, total) = _totalsAt(_toUint32(snapshotVersion));
    }

    /// @notice Number of registered holders (including those whose weight dropped to zero).
    function holderCount() external view returns (uint256) {
        return _holders.length;
    }

    /// @notice Number of registered holders as of `snapshotVersion`.
    function holderCountAt(uint256 snapshotVersion) external view returns (uint256 count) {
        (count,) = _totalsAt(_toUint32(snapshotVersion));
    }

    /// @notice The registered holder at `index` (0-based registration order).
    function holderAt(uint256 index) external view returns (address) {
        return _holders[index];
    }

    /// @notice Sum of stored weights for registration positions 1..`position` (inclusive), current version.
    function prefixWeight(uint256 position) external view returns (uint256) {
        return _prefixLatest(position);
    }

    // ---------------------------------------------------------------------------------------------
    // Fenwick tree with checkpointed nodes
    // ---------------------------------------------------------------------------------------------

    /// @dev Adds or subtracts `delta` from every existing node covering `position`, checkpointed at `v`.
    function _apply(uint256 position, uint32 v, uint256 delta, bool add) private {
        uint256 n = _holders.length;
        for (uint256 i = position; i <= n; i += i & (~i + 1)) {
            uint256 current = _tree[i].latest();
            _tree[i].push(v, _toUint224(add ? current + delta : current - delta));
        }
    }

    /// @dev Prefix sum over positions 1..`position` at the current version.
    function _prefixLatest(uint256 position) private view returns (uint256 sum) {
        for (uint256 i = position; i > 0; i -= i & (~i + 1)) {
            sum += _tree[i].latest();
        }
    }

    /// @dev Smallest position whose prefix sum at version `v` exceeds `target`; requires
    /// `target < total(v)` and `count` = number of holders at `v`.
    function _select(uint256 target, uint256 count, uint32 v) private view returns (uint256 position) {
        uint256 step = 1;
        while (step << 1 <= count) {
            step <<= 1;
        }
        uint256 remaining = target;
        for (; step > 0; step >>= 1) {
            uint256 next = position + step;
            if (next <= count) {
                uint256 nodeSum = _tree[next].upperLookup(v);
                if (nodeSum <= remaining) {
                    position = next;
                    remaining -= nodeSum;
                }
            }
        }
        position += 1;
    }

    // ---------------------------------------------------------------------------------------------
    // Versioning helpers
    // ---------------------------------------------------------------------------------------------

    function _bump() private returns (uint32 v) {
        version += 1;
        v = _toUint32(version);
    }

    function _pushTotals(uint32 v, uint256 count) private {
        _totals.push(v, (_toUint224(count) << 192) | _toUint224(totalWeight));
    }

    function _totalsAt(uint32 v) private view returns (uint256 count, uint256 total) {
        uint256 packed = _totals.upperLookup(v);
        count = packed >> 192;
        total = packed & ((uint256(1) << 192) - 1);
    }

    function _toUint32(uint256 x) private pure returns (uint32) {
        if (x > type(uint32).max) revert VersionTooLarge();
        return uint32(x);
    }

    function _toUint224(uint256 x) private pure returns (uint224) {
        // Weights are bounded by the token supply (10^27 < 2^90) and counts by the number of
        // registrations, both far inside 192 bits.
        return uint224(x);
    }
}
