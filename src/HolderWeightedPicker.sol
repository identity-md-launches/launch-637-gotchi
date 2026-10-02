// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title HolderWeightedPicker
/// @notice Deterministically selects a $GOTCHI holder with probability proportional to balance.
///
/// @dev Weighting model ("snapshot with live confirmation"):
///  - Holders opt in with `register()` (only for themselves, so contracts that merely hold tokens, such
///    as a distributor, are never entered by a third party). Registration records the holder's current
///    balance as their weight.
///  - `refresh(holder)` may be called by anyone, any time, and re-reads that holder's balance. Weights
///    are therefore a snapshot as of each holder's last refresh, not a live view. A UI or keeper should
///    refresh registered holders before a flip is revealed.
///  - `pick(randomness)` walks a Fenwick tree over the stored weights in O(log n) and returns the holder
///    whose cumulative range contains `randomness mod totalWeight`. It then reads that holder's *live*
///    balance once: if it is below the stored weight (tokens moved since the last refresh) the pick
///    forfeits and returns the zero address, which the escrow treats as a burn. This stops a holder from
///    inflating their odds by refreshing a balance and then moving the tokens elsewhere.
///  - Excluded, permanently: the zero address, the dead/burn address, the PoolManager (it holds the
///    pool's tokens) and this contract. Zero balances carry zero weight and can never be selected.
///
/// There is no admin role: the exclusion list is fixed in the constructor and nobody can edit weights.
contract HolderWeightedPicker {
    /// @notice Conventional burn address, never eligible.
    address public constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;
    /// @notice Maximum number of registered holders (Fenwick tree size, a power of two).
    uint256 public constant CAPACITY = 1 << 16;

    /// @notice The token whose balances are the weights.
    IERC20 public immutable TOKEN;
    /// @notice The Uniswap v4 PoolManager, excluded because it custodies the pool's tokens.
    address public immutable EXCLUDED_POOL_MANAGER;

    /// @notice Sum of all stored weights.
    uint256 public totalWeight;

    address[] private _holders;
    // 1-based position in `_holders` (0 = not registered).
    mapping(address holder => uint256 position) private _positionOf;
    mapping(address holder => uint256 weight) private _weightOf;
    // Fenwick tree over positions 1..CAPACITY.
    mapping(uint256 node => uint256 sum) private _tree;

    /// @notice A holder opted in with their current balance as weight.
    event HolderRegistered(address indexed holder, uint256 weight);
    /// @notice A registered holder's weight was re-read from the token.
    event WeightRefreshed(address indexed holder, uint256 oldWeight, uint256 newWeight);

    error ZeroAddress();
    error Excluded(address holder);
    error AlreadyRegistered(address holder);
    error NotRegistered(address holder);
    error ZeroBalance(address holder);
    error CapacityReached();

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
        if (_holders.length >= CAPACITY) revert CapacityReached();
        uint256 weight = TOKEN.balanceOf(holder);
        if (weight < 1) revert ZeroBalance(holder);

        _holders.push(holder);
        uint256 position = _holders.length;
        _positionOf[holder] = position;
        _weightOf[holder] = weight;
        totalWeight += weight;
        _add(position, weight);
        emit HolderRegistered(holder, weight);
    }

    /// @notice Re-reads `holder`'s balance into their weight. Anyone may call it for any registered holder.
    function refresh(address holder) external {
        uint256 position = _positionOf[holder];
        if (position < 1) revert NotRegistered(holder);
        uint256 oldWeight = _weightOf[holder];
        uint256 newWeight = TOKEN.balanceOf(holder);
        _weightOf[holder] = newWeight;
        if (newWeight > oldWeight) {
            uint256 diff = newWeight - oldWeight;
            totalWeight += diff;
            _add(position, diff);
        } else if (newWeight < oldWeight) {
            uint256 diff = oldWeight - newWeight;
            totalWeight -= diff;
            _sub(position, diff);
        }
        emit WeightRefreshed(holder, oldWeight, newWeight);
    }

    // ---------------------------------------------------------------------------------------------
    // Selection
    // ---------------------------------------------------------------------------------------------

    /// @notice Picks the holder whose weight range contains `randomness % totalWeight`.
    /// @return winner The selected holder, or the zero address when nobody is eligible or the selected
    /// holder's live balance fell below their stored weight.
    /// @return weight The stored weight the winner was selected with (0 when `winner` is zero).
    function pick(uint256 randomness) external view returns (address winner, uint256 weight) {
        if (totalWeight < 1) return (address(0), 0);
        uint256 target = randomness % totalWeight;
        uint256 position = _select(target);
        address candidate = _holders[position - 1];
        uint256 stored = _weightOf[candidate];
        uint256 live = TOKEN.balanceOf(candidate);
        if (live < stored) return (address(0), 0);
        return (candidate, stored);
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
        return _weightOf[holder];
    }

    /// @notice Number of registered holders (including those whose weight dropped to zero).
    function holderCount() external view returns (uint256) {
        return _holders.length;
    }

    /// @notice The registered holder at `index` (0-based registration order).
    function holderAt(uint256 index) external view returns (address) {
        return _holders[index];
    }

    /// @notice Sum of stored weights for registration positions 1..`position` (inclusive).
    function prefixWeight(uint256 position) external view returns (uint256 sum) {
        for (uint256 i = position; i > 0; i -= i & (~i + 1)) {
            sum += _tree[i];
        }
    }

    // ---------------------------------------------------------------------------------------------
    // Fenwick tree
    // ---------------------------------------------------------------------------------------------

    function _add(uint256 position, uint256 delta) private {
        for (uint256 i = position; i <= CAPACITY; i += i & (~i + 1)) {
            _tree[i] += delta;
        }
    }

    function _sub(uint256 position, uint256 delta) private {
        for (uint256 i = position; i <= CAPACITY; i += i & (~i + 1)) {
            _tree[i] -= delta;
        }
    }

    /// @dev Smallest position whose prefix sum exceeds `target`; requires `target < totalWeight`.
    function _select(uint256 target) private view returns (uint256 position) {
        uint256 remaining = target;
        for (uint256 step = CAPACITY; step > 0; step >>= 1) {
            uint256 next = position + step;
            if (next <= CAPACITY && _tree[next] <= remaining) {
                position = next;
                remaining -= _tree[next];
            }
        }
        position += 1;
    }
}
