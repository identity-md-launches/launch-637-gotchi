// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Checkpoints} from "@openzeppelin/contracts/utils/structs/Checkpoints.sol";

/// @title HolderWeightedPicker
/// @notice Deterministically selects a $GOTCHI holder with probability proportional to the GOTCHI they have
/// deposited here, against a block-keyed snapshot, so that nothing done once a flip's roll is knowable
/// can change who wins it.
///
/// @dev Weighting model ("custodied weight, snapshot per block"):
///  - A holder's weight is the amount of GOTCHI they have deposited into this contract (`deposit`) and
///    not withdrawn (`withdraw`). Tokens are custodied here, so one token can back exactly one weight at
///    a time: the same bag cannot be registered through several wallets, and a wallet's weight cannot be
///    moved to another wallet by a plain ERC-20 transfer. Only the depositor can deposit for or withdraw
///    to themselves, so a contract that merely holds GOTCHI (a distributor, a vesting wallet, a Safe) is
///    never entered without its consent.
///  - Every deposit and withdrawal checkpoints the touched Fenwick-tree nodes, the holder's weight and the
///    totals under the current block number (OpenZeppelin `Checkpoints`). `pickAt(snapshotBlock, r)`
///    answers against the registry exactly as it stood at the end of `snapshotBlock`; the FlipEscrow
///    resolves a flip with `pickAt(requestBlock - 1, roll)`, so a deposit made in the request block or
///    later (including a flash-loaned deposit, which must be undone in the same transaction) never counts,
///    and a withdrawal after the request does not change the outcome either. There is no live balance
///    check at resolution: eligibility depends on nothing that can change after the roll is knowable.
///  - Selection walks the Fenwick tree in O(log n) and returns the holder whose cumulative weight range at
///    the snapshot contains `randomness mod totalWeightAt(snapshotBlock)`. A holder whose weight at the
///    snapshot is zero has an empty range and can never be selected; when the total is zero nobody is
///    eligible and the zero address is returned (the escrow treats that as a burn).
///  - Excluded, permanently: the zero address, the dead/burn address, the PoolManager (it holds the
///    pool's tokens) and this contract. They can never deposit.
///  - The tree is append-only and unbounded: there is no registration cap to fill, and positions are
///    never reused, so historical snapshots stay valid.
///
/// There is no admin role: the exclusion list is fixed in the constructor and nobody can edit weights,
/// move deposits or touch past snapshots. GOTCHI sent here with a plain `transfer` (not `deposit`) belongs
/// to nobody and cannot be recovered; use `deposit`.
contract HolderWeightedPicker is ReentrancyGuard {
    using SafeERC20 for IERC20;
    using Checkpoints for Checkpoints.Trace224;

    /// @notice Conventional burn address, never eligible.
    address public constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    /// @notice The token deposited as weight.
    IERC20 public immutable TOKEN;
    /// @notice The Uniswap v4 PoolManager, excluded because it custodies the pool's tokens.
    address public immutable EXCLUDED_POOL_MANAGER;

    /// @notice Sum of all deposited weights (current state). Always equals the GOTCHI deposited here minus
    /// what was withdrawn.
    uint256 public totalWeight;

    address[] private _holders;
    // 1-based position in `_holders` (0 = never deposited).
    mapping(address holder => uint256 position) private _positionOf;
    // Weight history per holder, keyed by block number.
    mapping(address holder => Checkpoints.Trace224 history) private _weightHistory;
    // Fenwick tree over positions 1..n with a checkpoint history per node, keyed by block number.
    mapping(uint256 node => Checkpoints.Trace224 history) private _tree;
    // (holder count << 192 | total weight) per block.
    Checkpoints.Trace224 private _totals;

    /// @notice A holder deposited GOTCHI; `newWeight` is their weight afterwards.
    event Deposited(address indexed holder, uint256 amount, uint256 newWeight);
    /// @notice A holder withdrew GOTCHI; `newWeight` is their weight afterwards.
    event Withdrawn(address indexed holder, uint256 amount, uint256 newWeight);

    error ZeroAddress();
    error Excluded(address holder);
    error ZeroAmount();
    error NotRegistered(address holder);
    error InsufficientWeight(address holder, uint256 weight, uint256 requested);
    error BlockTooLarge();

    constructor(address token, address poolManager) {
        if (token == address(0) || poolManager == address(0)) revert ZeroAddress();
        TOKEN = IERC20(token);
        EXCLUDED_POOL_MANAGER = poolManager;
    }

    // ---------------------------------------------------------------------------------------------
    // Deposits and withdrawals
    // ---------------------------------------------------------------------------------------------

    /// @notice Deposits `amount` GOTCHI from the caller (approve first) and adds it to their weight. The
    /// first deposit registers the caller; later ones add to the same position.
    /// @return received The amount actually credited (what the token delivered).
    function deposit(uint256 amount) external nonReentrant returns (uint256 received) {
        address holder = msg.sender;
        if (isExcluded(holder)) revert Excluded(holder);
        if (amount < 1) revert ZeroAmount();

        uint256 before = TOKEN.balanceOf(address(this));
        TOKEN.safeTransferFrom(holder, address(this), amount);
        received = TOKEN.balanceOf(address(this)) - before;
        if (received < 1) revert ZeroAmount();

        uint32 key = _blockKey();
        uint256 position = _positionOf[holder];
        uint256 newWeight;
        if (position < 1) {
            _holders.push(holder);
            position = _holders.length;
            _positionOf[holder] = position;
            // Appending element `position` creates exactly one new Fenwick node, covering
            // (position - lowbit(position), position]. Existing nodes never cover a later position.
            uint256 lowbit = position & (~position + 1);
            uint256 nodeSum = received + _prefixLatest(position - 1) - _prefixLatest(position - lowbit);
            _tree[position].push(key, _toUint224(nodeSum));
            newWeight = received;
        } else {
            _apply(position, key, received, true);
            newWeight = _weightHistory[holder].latest() + received;
        }
        _weightHistory[holder].push(key, _toUint224(newWeight));
        totalWeight += received;
        _pushTotals(key);
        emit Deposited(holder, received, newWeight);
    }

    /// @notice Withdraws `amount` of the caller's deposited GOTCHI, reducing their weight from the current
    /// block on. Snapshots of earlier blocks are unaffected.
    function withdraw(uint256 amount) external nonReentrant {
        address holder = msg.sender;
        uint256 position = _positionOf[holder];
        if (position < 1) revert NotRegistered(holder);
        if (amount < 1) revert ZeroAmount();
        uint256 weight = _weightHistory[holder].latest();
        if (amount > weight) revert InsufficientWeight(holder, weight, amount);

        uint32 key = _blockKey();
        uint256 newWeight = weight - amount;
        _apply(position, key, amount, false);
        _weightHistory[holder].push(key, _toUint224(newWeight));
        totalWeight -= amount;
        _pushTotals(key);
        emit Withdrawn(holder, amount, newWeight);
        TOKEN.safeTransfer(holder, amount);
    }

    // ---------------------------------------------------------------------------------------------
    // Selection
    // ---------------------------------------------------------------------------------------------

    /// @notice Picks against the current state; see `pickAt`.
    function pick(uint256 randomness) external view returns (address winner, uint256 weight) {
        return pickAt(block.number, randomness);
    }

    /// @notice Picks the holder whose weight range, as of the end of `snapshotBlock`, contains
    /// `randomness % totalWeightAt(snapshotBlock)`. Pure function of the snapshot and `randomness`.
    /// @return winner The selected holder, or the zero address when nobody had weight at that block.
    /// @return weight The winner's weight at the snapshot (0 when `winner` is zero).
    function pickAt(uint256 snapshotBlock, uint256 randomness) public view returns (address winner, uint256 weight) {
        uint32 key = _toUint32(snapshotBlock);
        (uint256 count, uint256 total) = _totalsAt(key);
        if (total < 1) return (address(0), 0);
        uint256 position = _select(randomness % total, count, key);
        winner = _holders[position - 1];
        weight = _weightHistory[winner].upperLookup(key);
    }

    // ---------------------------------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------------------------------

    /// @notice Whether `holder` can never deposit.
    function isExcluded(address holder) public view returns (bool) {
        return
            holder == address(0) || holder == BURN_ADDRESS || holder == EXCLUDED_POOL_MANAGER || holder == address(this);
    }

    /// @notice Whether `holder` has ever deposited.
    function isRegistered(address holder) external view returns (bool) {
        return _positionOf[holder] > 0;
    }

    /// @notice The current deposited weight of `holder`; 0 when they never deposited or withdrew everything.
    function weightOf(address holder) external view returns (uint256) {
        return _weightHistory[holder].latest();
    }

    /// @notice The weight `holder` had at the end of `snapshotBlock`; 0 when not deposited by then.
    function weightOfAt(address holder, uint256 snapshotBlock) external view returns (uint256) {
        return _weightHistory[holder].upperLookup(_toUint32(snapshotBlock));
    }

    /// @notice The total deposited weight at the end of `snapshotBlock`.
    function totalWeightAt(uint256 snapshotBlock) external view returns (uint256 total) {
        (, total) = _totalsAt(_toUint32(snapshotBlock));
    }

    /// @notice Number of holders that ever deposited (including those whose weight is now zero).
    function holderCount() external view returns (uint256) {
        return _holders.length;
    }

    /// @notice Number of holders that had deposited by the end of `snapshotBlock`.
    function holderCountAt(uint256 snapshotBlock) external view returns (uint256 count) {
        (count,) = _totalsAt(_toUint32(snapshotBlock));
    }

    /// @notice The holder at `index` (0-based order of first deposit).
    function holderAt(uint256 index) external view returns (address) {
        return _holders[index];
    }

    /// @notice Sum of current weights for positions 1..`position` (inclusive).
    function prefixWeight(uint256 position) external view returns (uint256) {
        return _prefixLatest(position);
    }

    // ---------------------------------------------------------------------------------------------
    // Fenwick tree with checkpointed nodes
    // ---------------------------------------------------------------------------------------------

    /// @dev Adds or subtracts `delta` from every existing node covering `position`, checkpointed at `key`.
    function _apply(uint256 position, uint32 key, uint256 delta, bool add) private {
        uint256 n = _holders.length;
        for (uint256 i = position; i <= n; i += i & (~i + 1)) {
            uint256 current = _tree[i].latest();
            _tree[i].push(key, _toUint224(add ? current + delta : current - delta));
        }
    }

    /// @dev Prefix sum over positions 1..`position` at the current state.
    function _prefixLatest(uint256 position) private view returns (uint256 sum) {
        for (uint256 i = position; i > 0; i -= i & (~i + 1)) {
            sum += _tree[i].latest();
        }
    }

    /// @dev Smallest position whose prefix sum at `key` exceeds `target`; requires `target < total(key)`
    /// and `count` = number of holders at `key`. A zero-weight position is never returned.
    function _select(uint256 target, uint256 count, uint32 key) private view returns (uint256 position) {
        uint256 step = 1;
        while (step << 1 <= count) {
            step <<= 1;
        }
        uint256 remaining = target;
        for (; step > 0; step >>= 1) {
            uint256 next = position + step;
            if (next <= count) {
                uint256 nodeSum = _tree[next].upperLookup(key);
                if (nodeSum <= remaining) {
                    position = next;
                    remaining -= nodeSum;
                }
            }
        }
        position += 1;
    }

    // ---------------------------------------------------------------------------------------------
    // Checkpoint helpers
    // ---------------------------------------------------------------------------------------------

    function _blockKey() private view returns (uint32) {
        return _toUint32(block.number);
    }

    function _pushTotals(uint32 key) private {
        _totals.push(key, (_toUint224(_holders.length) << 192) | _toUint224(totalWeight));
    }

    function _totalsAt(uint32 key) private view returns (uint256 count, uint256 total) {
        uint256 packed = _totals.upperLookup(key);
        count = packed >> 192;
        total = packed & ((uint256(1) << 192) - 1);
    }

    function _toUint32(uint256 x) private pure returns (uint32) {
        if (x > type(uint32).max) revert BlockTooLarge();
        return uint32(x);
    }

    function _toUint224(uint256 x) private pure returns (uint224) {
        // Weights are bounded by the token supply (10^27 < 2^90) and counts by the number of
        // depositors, both far inside 192 bits.
        return uint224(x);
    }
}
