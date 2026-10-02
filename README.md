# $GOTCHI — Sepolia Foundry workflow

A standalone Foundry project for the **GOTCHI** ERC-20 paired with ETH in a simple, forever-locked
Uniswap v4 pool on **Sepolia (chainId 11155111)**. A v4 hook skims a 0.30% ETH fee from every swap into a
FeeSink; once the sink holds at least 0.01 ETH anyone can crank it to buy the cheapest mock Aavegotchi
listed on a mock Baazaar; the FlipEscrow then resolves each acquisition 50/50 with commit-reveal mock
randomness: burn it, or airdrop it to a $GOTCHI holder picked by balance weight. Every step emits the
events a future cliff/flame/parachute UI needs. Events only; no UI art.

```
swap on ETH/$GOTCHI ──► GotchiFeeHook ──take(ETH)──► FeeSink ──triggerBuy()──► MockBaazaar.buyCheapest
                                                                                      │ NFT
                                                                                      ▼
            HolderWeightedPicker ◄──pick(roll)── FlipEscrow ◄──commit / reveal── operator
                                                   │
                                   burn (0x…dEaD) ◄┴► airdrop to weighted holder
```

Scope: Sepolia only. No Base deployment, no Base cutover, no live Baazaar, no real Aavegotchi NFTs, no
Community-Coins split, no launchpad/bonding template, no 4 ETH graduation, no virtual bonding curve.
Base / Diamond / real-Baazaar integration and Chainlink VRF migration are TODOs at the end of this file.

## Contents

| Path | What |
|---|---|
| `src/LaunchToken.sol` | **GotchiToken**: the GOTCHI ERC-20 (fixed 1,000,000,000 supply, 18 decimals) |
| `src/GotchiFeeHook.sol` | **FeeCollector hook**: v4 hook, constructor takes only the PoolManager |
| `src/FeeSink.sol` | receives fee ETH, permissionless crank buys the cheapest listing for the escrow |
| `src/MockBaazaar.sol` | mock ETH-priced marketplace: `list`, `cancel`, `buyCheapest`, pull payments |
| `src/MockAavegotchi.sol` | mock ERC-721 collection sold on the mock Baazaar |
| `src/FlipEscrow.sol` | holds bought NFTs, commit-reveal flip: burn or weighted airdrop |
| `src/HolderWeightedPicker.sol` | opt-in registry + Fenwick tree, deterministic balance-weighted pick |
| `src/ForeverLiquidity.sol` | owns the pool's full-range position; nothing can ever remove it |
| `src/GotchiStackDeployer.sol` | one-shot helper: hook (CREATE2) + FeeSink + ForeverLiquidity + pool init in one transaction |
| `src/PriceMath.sol` | amounts → sqrtPriceX96, shared by `ForeverLiquidity` and the deploy script |
| `src/HookFlags.sol`, `src/HookMiner.sol` | hook permission bits and CREATE2 salt mining |
| `script/DeployGotchiSepolia.s.sol` | optional Sepolia deploy of everything + pool init + initial liquidity |
| `abi/*.json` | exported ABIs for the nine contracts (`forge inspect <Name> abi --json`) |
| `test/*.t.sol` | 136 tests, see "Tests" |
| `lib/` | vendored dependencies as ordinary files (forge-std 1.16.2, OpenZeppelin 5.7.0, v4-core 1.0.2, solmate `Owned`) |

## Build and test

```
forge build
forge test
forge fmt --check
```

`foundry.toml` pins `solc = "0.8.26"`, `evm_version = "cancun"` (v4 uses transient storage), optimizer on
(200 runs, no via-IR), `bytecode_hash = "none"`, `ffi = false`, no filesystem permissions. Everything
compiles offline from the vendored `lib/`. Tests read no environment variables, use no live RPC and do not
depend on the calling address; the v4 `PoolManager` is deployed locally in every test.

Regenerate ABIs after a source change:

```
for c in LaunchToken GotchiFeeHook FeeSink MockAavegotchi MockBaazaar FlipEscrow HolderWeightedPicker ForeverLiquidity GotchiStackDeployer; do
  forge inspect $c abi --json > abi/$c.json
done
```

## Key parameters

| Parameter | Value | Where |
|---|---|---|
| Token name / symbol | GOTCHI / GOTCHI, 18 decimals, 10^27 minor units | `LaunchToken` |
| Pair | native ETH (currency0) / $GOTCHI (currency1) | `ForeverLiquidity.poolKey()` |
| Pool LP fee / tick spacing | 0 pips / 60, full range [-887220, 887220] | `ForeverLiquidity` |
| `FEE_BPS` | 30 (0.30% of the ETH side of each swap) | `GotchiFeeHook` |
| `MIN_BUY_THRESHOLD` | 0.01 ether | `FeeSink` |
| `MAX_BUY_PRICE` | 0.1 ether (10x the threshold); the most one purchase may pay | `FeeSink` |
| `FLIP_BURN_BPS` | 5000 (50%) | `FlipEscrow` |
| `BURN_ADDRESS` | `0x000000000000000000000000000000000000dEaD` | `FlipEscrow`, `HolderWeightedPicker` |
| Reveal window / pending timeout | 7,200 blocks each (~1 day on Sepolia) | `FlipEscrow` |
| Max active listings | 128 (`cheapest()` scans only the active index) | `MockBaazaar` |
| Picker registry | unbounded (append-only Fenwick tree); `MAX_DRAWS` = 8 re-draws past stale weights | `HolderWeightedPicker` |
| `MIN_REALISED_FEE_PERCENT` | 90: an ETH-specified swap must pay at least 90% of 30 bps of its net ETH | `GotchiFeeHook` |
| PoolManager | `0xE03A1074c86CFeDd5C142C4F04F1a1536e203543` (Sepolia) | hook constructor arg, deploy script |
| Hook address flags | `0xCC` = beforeSwap, afterSwap, beforeSwapReturnDelta, afterSwapReturnDelta | `GotchiFeeHook.HOOK_FLAGS` |
| `INITIAL_LIQUIDITY_ETH` | **TBD**, default 0.1 ETH | deploy script `GOTCHI_INITIAL_ETH` |
| `INITIAL_LIQUIDITY_TOKENS` | **TBD**, default 100,000,000 GOTCHI (10% of supply) | deploy script `GOTCHI_INITIAL_TOKENS` |
| Implied launch price / mcap | with the defaults: 10^9 GOTCHI per ETH, 1 ETH fully-diluted | derived |

The initial liquidity and the resulting price/mcap are **deploy-time configuration**, not contract
constants: `ForeverLiquidity.sqrtPriceX96ForAmounts(eth, tokens)` turns the two amounts into the pool's
opening price and `liquidityForAmounts` into the position size. Change the two env vars (or the script
defaults) before broadcasting.

## Events (indexed fields are stable for the UI)

```solidity
event FeesCollected(address indexed pool, uint256 amountEth);                  // FeeSink  (pool = sender; the PoolManager for hook fees)
event BuyTriggered(uint256 indexed listingId, uint256 priceEth, uint256 tokenId); // FeeSink
event FlipRequested(uint256 indexed acquisitionId, uint256 tokenId, bytes32 requestId); // FlipEscrow
event FlipResolved(uint256 indexed acquisitionId, uint256 tokenId, bool burned, address indexed recipient); // FlipEscrow
event Burned(uint256 indexed tokenId, address indexed to);                     // FlipEscrow
event Airdropped(uint256 indexed tokenId, address indexed recipient, uint256 weight); // FlipEscrow
event ListingMocked(uint256 indexed listingId, uint256 tokenId, uint256 price); // MockBaazaar
```

Extra events for richer feeds: `GotchiFeeHook.HookFeeTaken(PoolId indexed, address indexed sink, uint256)`,
`GotchiFeeHook.FeeSinkBound`, `MockBaazaar.Sold / ListingCancelled / ProceedsWithdrawn`,
`FlipEscrow.AcquisitionReceived / RandomnessCommitted / FlipRevealed / FlipExpired / StraySwept`,
`HolderWeightedPicker.HolderRegistered / WeightRefreshed`, `ForeverLiquidity.LiquidityLocked`,
`GotchiStackDeployer.StackDeployed`.

`FeesCollected.pool` is the address that paid the sink: the PoolManager for hook fees, the donor for
donations. The pool a fee came from is identified by `HookFeeTaken(poolId, …)` emitted by the hook in the same
transaction; a UI indexing fees per pool joins the two. The brief fixes the event's shape, and the hook never
holds ETH (the PoolManager pays the sink directly), so the sink cannot learn the pool id itself.

## How each module works

### LaunchToken (GotchiToken)

Plain OpenZeppelin ERC-20. The constructor mints the whole 10^27 supply to `msg.sender` and that is the
only mint that will ever happen: no owner, no `mint`, no pause, blocklist, fee or upgrade path. The brief
calls this module "GotchiToken"; the contract is named `LaunchToken` (file `src/LaunchToken.sol`) because
that is the name the launch tooling expects. Nothing the brief asks for requires the token to do more than
transfer, so nothing was left out of it.

### GotchiFeeHook (FeeCollector)

* Constructor argument: the PoolManager address only. No token, sink or sibling placeholder.
* Enabled callbacks: `beforeSwap`, `afterSwap`, with return deltas on both. **No `beforeInitialize`**,
  no pad-bound or sender gate: anyone can initialize a pool with this hook. Liquidity and donate callbacks
  are off and revert `HookNotImplemented` if ever called.
* Fee mechanics. ETH is currency0 in every native pool.
  * ETH *unspecified* (exact-output ETH sale, exact-input ETH purchase): `afterSwap` returns a positive
    unspecified delta equal to `FEE_BPS` of the ETH the swap actually moved. Exact by construction.
  * ETH *specified* (exact-input ETH sale, exact-output ETH purchase): only `beforeSwap` can charge the
    specified side, before the fill is known, so it sizes the fee on the ETH the swap **can** move:
    `feeFor(min(|amountSpecified|, ethToLimit))`, where `ethToLimit` is the ETH the pool moves between the
    spot price and the trader's `sqrtPriceLimitX96` at the spot liquidity (the same `SqrtPriceMath` the pool
    uses). A swap that fills completely pays 30 bps of its amount, as before. A swap the price limit cuts
    short pays 30 bps of what filled, not of what was requested, so a price-limited exact-output ETH buyer
    nets `fill − fee ≥ 0` and never pays ETH. The fee travels from `beforeSwap` to `afterSwap` in transient
    storage; `afterSwap` checks it against the realised fill and reverts `FeeOutOfBounds` if it exceeds
    30 bps of the gross ETH (plus one wei of rounding) or falls below `MIN_REALISED_FEE_PERCENT` (90%) of
    30 bps of the net ETH. The lower bound stops a trader from shaping liquidity (a deep position just past
    the spot) to shrink a pre-sized fee. Consequence: an ETH-specified swap whose limit runs through
    third-party positions whose liquidity differs a lot from the spot liquidity may revert; use a different
    limit or specify the GOTCHI side. Swaps with the usual MIN/MAX limits are never affected.
  * In both cases `afterSwap` immediately `take`s the credited ETH out of the PoolManager **to the FeeSink**
    (the PoolManager pays the sink directly; the hook never holds ETH or tokens and no `call{value}` lives
    in the hook). Non-ETH pools using the hook pay no fee; an ETH pool pays no fee until a sink is bound.
* Wiring: `feeSink` is zero at construction. The FeeSink's constructor calls `bindFeeSink()`, which sets
  `feeSink = msg.sender` **once**; there is no setter, owner or way to redirect fees afterwards (no hidden
  treasury). Binding is first come, first served, so **the hook and the FeeSink must be created in one
  transaction**: the deploy script does it through `GotchiStackDeployer.deploy`, and a launch factory that
  deploys both in one transaction is equally safe. A hook created on its own and left unbound for even one
  block can be claimed by a stranger and must then be abandoned (nothing can rebind it).
* Address flags are **not** validated in the constructor (a factory picks its own CREATE2 salt, and the
  reviewer's proof harness and the launch floor deploy the hook at arbitrary addresses). The stack deployer
  and the script mine a salt so the address carries exactly `0xCC` and refuse to continue otherwise. A hook
  at an address without those bits is inert: the PoolManager either refuses to initialize a pool with it or
  calls callbacks that revert. **A factory that cannot mine a salt for this contract cannot produce a working
  hook pool**; check `addressHasValidFlags()` after any deployment and redeploy if it is false.

### FeeSink

* `receive()` accepts ETH from anyone (the PoolManager for fees, donations otherwise), records
  `totalCollected` and emits `FeesCollected(msg.sender, amount)`.
* `triggerBuy()` is a **permissionless crank**: reverts `BelowThreshold` under 0.01 ETH, `NoListing` when
  the Baazaar is empty, `CannotAfford` when the cheapest listing costs more than the balance, and
  `PriceAboveCap` when it costs more than `MAX_BUY_PRICE` (0.1 ETH). Otherwise it arms
  `pendingPayment = price`, emits `BuyTriggered`, calls `MockBaazaar.buyCheapest(escrow, price)` and
  verifies the listing/token/price it got back and that the payment was collected. The buy is not run inside
  the swap on purpose: swaps stay cheap and marketplace state can never block trading. A keeper, the UI or
  anyone else calls the crank; `canBuy()` says whether it would succeed and what it would buy.
* The price cap bounds what whoever controls the cheapest listing can extract per gotchi: without it a
  seller with the only listing could price it at the sink's whole balance. Fees above the cap simply
  accumulate until a listing at or below it exists.
* ETH leaves the sink **only** through `payForListing`, which the Baazaar calls back during the crank. It
  checks `msg.sender == BAAZAAR`, that the amount equals the armed `pendingPayment`, disarms, then pays.
* Reentrancy: `triggerBuy` is `nonReentrant` (OpenZeppelin guard); `payForListing` disarms before paying so
  a second call fails; all sibling addresses are immutable. Tested with a malicious marketplace that
  re-enters from inside the callback.
* No admin: nobody can withdraw, redirect or change the threshold. If the Baazaar never has an affordable
  listing the ETH simply waits.

### MockBaazaar and MockAavegotchi

* `MockAavegotchi` is a plain ERC-721 with a `MINTER` role (set in the constructor) that is the only way to
  create tokens. It is a mock, not the Aavegotchi Diamond.
* `list(tokenId, price)` escrows the NFT in the Baazaar (owner + approval required, price > 0, at most 128
  active listings). `cancel` returns it to the seller. Active listing ids live in a separate index
  (`activeListingIdAt`, swap-and-pop on cancel or sale) and `cheapest()` scans **only that index**: lowest
  price, ties to the oldest id. Listings ever created (`listingCount`) can grow without bound through
  list/cancel cycles without making the scan, and so `FeeSink.triggerBuy`, any dearer.
* `buyCheapest(recipient, maxPrice)` works two ways: with `msg.value` (excess refunded) for wallets, or with
  `msg.value == 0` for contracts implementing `IBaazaarBuyer` (the Baazaar calls `payForListing` and checks
  its own balance grew by the price). The NFT is `safeTransferFrom`'d to `recipient`.
* Sellers are paid by **pull** (`proceeds`, `withdrawProceeds`), so a seller that reverts on ETH can never
  block a purchase. `receive()` accepts ETH only from the buyer whose payment callback is running, so stray
  ETH (which no seller could claim) is refused. No admin role.
* Anyone who owns a mock gotchi can list it and buy it back with the escrow as recipient, paying the listing
  price to themselves; that creates an acquisition the FeeSink did not pay for and consumes one operator
  commitment. The escrow cannot tell such a purchase from the sink's (it does not know the sink, which is
  deployed after it) and the mock accepts this: it costs the third party a listing price plus gas and gives
  them nothing but a 50/50 flip of their own NFT among registered holders.

### FlipEscrow

* Only accepts NFTs delivered by the configured NFT contract **from the Baazaar** (i.e. purchases). Each
  delivery becomes an acquisition (`AcquisitionReceived`).
* Randomness is a **commit-reveal mock**. The `OPERATOR` queues `keccak256(abi.encodePacked(secret))`
  commitments (`commit`, `commitMany`). An acquisition binds to the oldest unused commitment, provided that
  commitment was made in an **earlier block than the binding** (`FlipRequested`, `requestId` =
  `keccak256(escrow, chainId, acquisitionId, tokenId, commitmentIndex, hash)`). If the queue is empty, or its
  head was committed in the current block, the acquisition waits as `Pending`; once a commitment from an
  earlier block exists, anyone binds it with `requestFlip` (a commitment made *after* the NFT arrived is
  eligible). Binding records `HolderWeightedPicker.version()`: the set of eligible holders and their weights
  for this flip is frozen at that moment.
* Anyone who knows the secret calls `reveal`: `roll = keccak256(secret, requestId)`; `roll % 10_000 < 5_000`
  burns, otherwise `picker.drawAt(frozenVersion, roll)` chooses the recipient against the frozen registry.
  Nothing registered or refreshed after the request counts, so seeing the secret in the mempool gives a
  front-runner no lever. No eligible holder at the frozen version, or every draw stale, falls back to a burn.
* Forced burns: a bound acquisition whose secret is not revealed within `REVEAL_WINDOW_BLOCKS`, or a
  `Pending` one that never got a commitment within `PENDING_TIMEOUT_BLOCKS`, can be `expire`d by anyone
  and is burned (`FlipExpired`, `FlipResolved(burned = true)`).
* Resolution order is effects → events → one `transferFrom` (not `safeTransferFrom`, so a recipient that
  cannot receive NFTs can never block the pipeline).
* `sweepStray(tokenId)` (anyone) burns a gotchi that sits in the escrow without an open acquisition: one
  pushed in with a plain `transferFrom` (no callback, so it never became an acquisition) or returned after
  its flip resolved. Nothing else can ever move such a token.
* **Trust model of the mock, read before relying on the 50/50.** Every input of the roll (next acquisition
  id, the token that will be bought, next commitment index, and the hash the operator chooses) is known to
  the operator before committing. The operator can therefore grind secrets off-chain and **choose each
  flip's outcome and, through the picker, its winner**, and can withhold a reveal to force a burn. The
  escrow protects holders against *third parties* (nobody else learns the roll before the reveal, and the
  eligible set is frozen at the request), not against the operator. The operator is trusted for fairness,
  not only liveness, until Chainlink VRF replaces the commitment queue (TODO; no subscription/keys were
  available in this job). The operator must also never disclose a secret before its acquisition is
  `Requested`: a leaked secret lets anyone grind registrations against the future roll.

### HolderWeightedPicker

* **Opt-in registry.** A holder calls `register()` for themselves (so nobody can enter a contract such as
  the launch distributor, a vesting wallet or a Safe without its consent). Registration stores the current
  balance as the weight. Excluded forever: the zero address, the dead address, the PoolManager (it
  custodies the pool's tokens) and the picker itself. Zero balances cannot register and carry zero weight.
* **Versioned snapshot weighting with live confirmation.** Weights are the balance as of each holder's
  last `refresh(holder)` (anyone may refresh anyone). Every effective `register`/`refresh` increments
  `version` and checkpoints the touched Fenwick-tree nodes, the holder's weight and the totals under it
  (OpenZeppelin `Checkpoints`). `pickAt(version, randomness)` selects `randomness % totalWeightAt(version)`
  over the tree as it stood at that version (O(log n) nodes, each a binary search over its checkpoints);
  `pick(randomness)` is the same at the current version. The FlipEscrow freezes `version()` when a flip is
  requested and resolves with it, so nothing done after the request changes who wins.
* The selected holder's **live** balance is read once: if it is below the snapshot weight the draw forfeits
  and the picker re-draws deterministically (`keccak256(randomness, i)`), up to `MAX_DRAWS` = 8 draws in
  total; only when every draw forfeits does the flip burn. This blocks "refresh then move the tokens
  elsewhere" double counting and keeps stale entries from turning honest holders' airdrops into burns.
  `drawAt` (what the escrow calls) additionally `refresh`es every stale holder it lands on, under a new
  version, so entries backed by tokens that moved on (one bag registered through several wallets) lose their
  weight for all later flips. Keepers may still `refresh` stale wallets proactively; it is the same call.
* The registry is **append-only and unbounded**: a new holder creates exactly one new tree node, there is no
  capacity to fill, and positions are never reused (so historical versions stay valid).
* Gas: registering costs about 230k with ~1,000 holders (one new node, two prefix walks, three checkpoints);
  a reveal with one eligible draw costs a few hundred thousand; the adversarial worst case (seven stale draws,
  each refreshed) stays under ~3M.
* `Airdropped.weight` is the snapshot weight the winner was selected with.
* No admin role; the exclusion list is fixed at construction.

### ForeverLiquidity (the simple/forever pool)

* Defines the pool key: ETH / GOTCHI, LP fee 0, tick spacing 60, this project's hook. With an LP fee of
  zero the hook's 0.30% ETH skim is the whole trading fee and no LP fee ever accrues to the position (no
  hidden treasury; asserted in tests).
* `initializePool(sqrtPriceX96)` (anyone, once — the PoolManager refuses a second call). The pool key is
  fixed once the token and hook addresses are known, so `GotchiStackDeployer` initializes it in the same
  transaction that creates the hook and this contract; nobody can pin it at another price first.
* `addLiquidity(liquidity, maxTokens)` payable (anyone) quotes at whatever price the pool has;
  `addLiquidityWithin(liquidity, maxTokens, minSqrtPriceX96, maxSqrtPriceX96)` reverts `PriceOutsideBounds`
  unless the live price is inside the band, so a deposit computed for one price is never taken at another
  (the script uses an exact band). The contract owns the single full-range position; **there is no function
  to remove liquidity, collect or transfer the position**. Unused ETH/tokens are refunded; the contract
  never keeps a balance.
* Tokens are pulled from `msg.sender` only (never from a stored payer), and the contract pays the
  PoolManager from its own balance inside `unlockCallback`, which only the PoolManager can call.
* Quoting helpers: `sqrtPriceX96ForAmounts` (via `PriceMath`; reverts `PriceOutOfRange` for ratios of
  2^64 tokens per wei and above or outside the tick range, never panics), `liquidityForAmounts`,
  `amountsForLiquidity` (uses the pool's own rounding; the callback checks the PoolManager asked for exactly
  the quoted amounts).

### GotchiStackDeployer

A one-shot helper for the script path. `deploy(salt, token, baazaar, escrow, sqrtPriceX96)` creates, in one
transaction: the hook at `CREATE2(deployer, salt)` (refusing a salt whose address lacks `0xCC`), the FeeSink
(whose constructor binds itself to the hook; the helper asserts the binding), `ForeverLiquidity` for that hook,
and the pool initialization at the given price. Only `DEPLOYER` (the account that created the helper) may
call it, so a stranger cannot consume a mined salt. The helper holds nothing and has no power over the
contracts afterwards. A launch factory that deploys the hook and the FeeSink in one transaction does not need
it; the hook's constructor still takes only the PoolManager.

## Admin roles and trust assumptions

| Contract | Role | Power | Cannot |
|---|---|---|---|
| LaunchToken | none | — | mint, pause, block, tax, upgrade |
| GotchiFeeHook | none (one-time self-binding by the FeeSink, first come first served) | — | change fee, redirect fees, pause, gate pools |
| FeeSink | none | — | withdraw, redirect, change threshold or cap |
| MockAavegotchi | `MINTER` (immutable) | mint mock gotchis; as the only source of inventory, decides what the sink can buy and (within `MAX_BUY_PRICE`) at what price | burn, pause, move others' tokens |
| MockBaazaar | none | — | delist/reprice others, take proceeds |
| HolderWeightedPicker | none | — | edit weights, exclusions or past snapshots |
| FlipEscrow | `OPERATOR` (immutable) | queue randomness commitments; **by grinding secrets, choose each flip's outcome and winner**; withhold a reveal (→ burn) | move an NFT outside a resolution, change a frozen eligible set, skip the 7,200-block windows |
| ForeverLiquidity | none | — | remove liquidity, collect fees |
| GotchiStackDeployer | `DEPLOYER` (immutable, the script's broadcaster) | call `deploy` | anything after deployment |

Nothing is upgradeable, nothing uses `delegatecall` or `selfdestruct`, there is no post-deploy mint and no
fee treasury other than the FeeSink, whose only outflow is the Baazaar purchase. **The operator is trusted
for the fairness of every flip under the commit-reveal mock, not just for liveness**: the roll's inputs are
all known to them before they commit (see the FlipEscrow trust model above). Any lister who controls the
cheapest listing sets, within the cap, how much fee ETH one gotchi costs. Passing tests are not an audit: an
independent adversarial review is still required before anything holding third-party funds goes live.

## Static-analysis notes

An earlier attempt at this job was rejected by static analysis (an `arbitrary-send-erc20` in a liquidity
helper that pulled tokens from a stored payer). The design keeps those patterns out:

* no `transferFrom`/`safeTransferFrom` with a stored or caller-supplied `from` (always `msg.sender` or
  `address(this)`);
* every `call{value}` is either gated by a `msg.sender` check (`FeeSink.payForListing`,
  `ForeverLiquidity.unlockCallback`), a refund of `msg.value` (`MockBaazaar.buyCheapest`,
  `ForeverLiquidity.addLiquidity`) or a `proceeds[msg.sender]` withdrawal; the hook moves ETH only through
  `PoolManager.take`;
* no strict equality on balances or block numbers in control flow (balance checks are `>=`/`<`,
  commitment eligibility is `<`); no `block.timestamp` anywhere (windows are in blocks); no
  `blockhash`/`prevrandao` in the roll;
* every local is initialized, every external return value is captured, state and events come before
  external calls where the order is free, and every state-changing entry point with an external call is
  `nonReentrant`.

Known lint-level items, all reviewed and intentional: `calls-loop` in the picker's bounded re-draw loop
(at most `MAX_DRAWS` `balanceOf` reads of the launch token); `reentrancy-events` where a resolution event
follows `drawAt` inside the `nonReentrant` `reveal`, and in `GotchiStackDeployer` whose only callees are
contracts it just created; `reentrancy-balance` on the intended before/after balance check in `buyCheapest`;
`unsafe-typecast` after explicit range checks; `require-revert-in-loop` in `commitMany`. Slither could not be
run on the build machine (no `pip`).

## Tests (136)

| Suite | Covers |
|---|---|
| `LaunchToken.t.sol` | supply, decimals, transfer exactness, no admin/mint selectors, no escape opcodes |
| `GotchiFeeHook.t.sol` | flags = v4-core constants, address validity, one-time binding, **fee in all four swap directions vs an un-hooked reference pool**, accumulation, rounding, no fee unbound / on token-token pools, caller gating, disabled callbacks, **price-limited partial fills in both ETH-specified directions (fee = 30 bps of the fill, buyer never pays ETH)**, limit estimate vs the pool's own fill, unbounded estimate for rejected limits, **liquidity shaped to shrink the fee is rejected** |
| `FeeSink.t.sol` | receive + event, **threshold/no-listing/unaffordable/above-cap no-buy**, successful buy (seller credit, escrow custody, counters), repeat buys, payment callback gating, **reentrancy from a malicious marketplace** |
| `MockBaazaar.t.sol` | minter role, list/cancel/cap, **cheapest selection and tie-break**, **active index swap-and-pop, scan cost flat after 2,000 dead listings**, tie-break under a reordered index, stray ETH refused, value and callback purchases, refunds, unpaid revert, **pull payments and a seller that rejects ETH** |
| `HolderWeightedPicker.t.sol` | exclusions, zero balance, double registration, refresh up/down, **deterministic range selection**, re-draw past stale weights, forfeit only when every draw is stale, **sybil/stale entries cleaned by `drawAt`**, **versioned snapshots (`pickAt`, `weightOfAt`, `totalWeightAt`, `holderCountAt`) ignore later registrations and refreshes**, no capacity cap (300 holders), fuzz |
| `FlipEscrow.t.sol` | operator gating, intake gating, commitment eligibility (earlier block than the binding) and FIFO order, **pending acquisitions bind later commitments via `requestFlip`**, **burn path, airdrop path**, no-eligible-holder / all-stale burns and re-draws, **registration or refresh after the request cannot change the winner**, bad secret, window close, **forced burn on withheld reveal and on pending timeout**, stray NFT sweep |
| `ForeverLiquidity.t.sol` | key/constants, seeded position, double init, price math incl. out-of-range ratios, quoting, add with refunds, **price-band guard**, underfunding, callback gating, no removal path, no LP fee accrual |
| `EndToEnd.t.sol` | **swaps → fees → buy → flip (burn and airdrop) with the full event trail**, below-threshold no-buy in the middle, conservation of ETH, forced-burn variants, **empty-queue purchase flipped once the operator commits** |
| `DeployScript.t.sol` | the script's `deploy(Config)` against a local PoolManager: wiring, mined hook address from the stack deployer, pool price/liquidity, supply, **stack deployer atomicity and caller restriction** |
| `ProjectFloor.t.sol` | constructors against the literal Sepolia PoolManager leave the supply untouched, EIP-170 size, no DELEGATECALL/CALLCODE/SELFDESTRUCT |

## Deployment (optional, Sepolia)

```
forge script script/DeployGotchiSepolia.s.sol --rpc-url $SEPOLIA_RPC                             # simulate
forge script script/DeployGotchiSepolia.s.sol --rpc-url $SEPOLIA_RPC --broadcast --slow --verify  # deploy
```

Use `--slow`: it waits for each receipt before sending the next transaction, so a failed step stops the run
instead of letting later transactions build on it. Environment (all optional): `GOTCHI_OPERATOR`,
`GOTCHI_MINTER` (default: the broadcaster), `GOTCHI_INITIAL_ETH` (default 0.1 ether),
`GOTCHI_INITIAL_TOKENS` (default 100,000,000 GOTCHI).

What `run()` does, in order: refuses any chain but Sepolia; deploys `LaunchToken` (supply to the
broadcaster), `MockAavegotchi`, `MockBaazaar`, `HolderWeightedPicker`, `FlipEscrow` and a fresh
`GotchiStackDeployer`; mines a CREATE2 salt against the helper's address so the hook address carries `0xCC`
(a fresh helper means the salt is unused by construction); calls `GotchiStackDeployer.deploy`, which in **one
transaction** creates `GotchiFeeHook(0xE03A…3543)`, `FeeSink` (binding itself to the hook) and
`ForeverLiquidity`, and initializes the pool at the price implied by the two liquidity amounts; then approves
and adds the initial forever liquidity with `addLiquidityWithin` at exactly that price. The script asserts the
mined address, the flags and the binding, and logs every address and the salt. Nothing between the hook's
creation and the sink's binding, or between `ForeverLiquidity`'s creation and the pool initialization, is
visible to the mempool.

Deployment order / constructor arguments, for a factory or manifest:

| # | Contract | Constructor args |
|---|---|---|
| 0 | `LaunchToken` | — |
| 1 | `GotchiFeeHook` | `0xE03A1074c86CFeDd5C142C4F04F1a1536e203543` (CREATE2 salt must give an address with low 14 bits `0xCC`) |
| 2 | `MockAavegotchi` | minter address |
| 3 | `MockBaazaar` | `MockAavegotchi` |
| 4 | `HolderWeightedPicker` | `LaunchToken`, PoolManager |
| 5 | `FlipEscrow` | `MockAavegotchi`, `MockBaazaar`, `HolderWeightedPicker`, operator address |
| 6 | `FeeSink` | `GotchiFeeHook`, `MockBaazaar`, `FlipEscrow` (same transaction as the hook; binds itself) |
| 7 | `ForeverLiquidity` | `LaunchToken`, PoolManager, `GotchiFeeHook` |

`GotchiStackDeployer` is a script-path helper, not a manifest contract: a factory that deploys 1–7 in one
transaction gets the same atomicity. All constructors are nonpayable with address-only arguments and make no
supply-moving calls. **A factory must still place the hook at an address carrying `0xCC`**; the hook does not
validate its own address (the proof harness and the launch floor deploy it at arbitrary addresses), so a hook
at the wrong address deploys fine and is then inert, and the pool cannot be initialized for it. If a launch
factory deploys these, note that its own token pool (with its own guard hook) is a different pool from the
ETH/$GOTCHI hook pool described here; the fee hook applies only to pools initialized with
`ForeverLiquidity.poolKey()` (or any other native-ETH pool someone initializes with this hook), and that pool
has to be initialized by someone after the launch (`ForeverLiquidity.initializePool`).

### Operational responsibilities

* **Broadcaster**: funds `GOTCHI_INITIAL_ETH` plus gas, receives the token supply, runs the script with
  `--slow`, verifies sources on the explorer (`forge verify-contract`), checks `hook.feeSink() == sink` and
  `hook.addressHasValidFlags()` after deployment (redeploy if either fails).
* **Operator** (`FlipEscrow.OPERATOR`): keeps a buffer of commitments queued *ahead* of purchases
  (`commitMany`), stores the secrets safely, never discloses a secret before its acquisition is `Requested`,
  reveals within 7,200 blocks. A missed reveal turns the flip into a burn; an empty queue leaves the
  acquisition `Pending` until a commitment exists (then anyone binds it) or 7,200 blocks pass (then anyone
  burns it). The operator is trusted for fairness under the mock (see the trust model).
* **Minter** (`MockAavegotchi.MINTER`): mints demo gotchis and lists them (`approve` + `list`) at or below
  `MAX_BUY_PRICE` so the sink has something to buy.
* **Keepers / UI**: call `FeeSink.triggerBuy()` when `canBuy()` is true, `FlipEscrow.requestFlip` for
  pending acquisitions once a commitment from an earlier block exists, `HolderWeightedPicker.refresh` for
  registered holders whose balance changed (ideally before a purchase binds a flip, since the eligible set
  freezes at the request), `FlipEscrow.expire` for stuck ones and `FlipEscrow.sweepStray` for NFTs pushed in
  without a purchase. All of these are permissionless.
* **Holders**: `register()` once to be eligible for airdrops; refresh after balance changes (a balance below
  the snapshot weight forfeits the draw).
* **Sellers**: `withdrawProceeds()` to collect ETH from sales.

## Assumptions

* The Sepolia PoolManager at `0xE03A1074c86CFeDd5C142C4F04F1a1536e203543` is the Uniswap v4 singleton with
  the v4-core 1.0.2 interface vendored here; the tests run against a locally deployed copy of that code.
* Native ETH is currency0 of the pool, so "ETH side" always means `amount0`.
* Fees are taken only on swaps (not on liquidity changes or donations), only on native-ETH pools, and only
  once a sink is bound. For ETH-specified swaps the fee is sized before the fill from the spot liquidity and
  the trader's price limit, and verified afterwards; swaps whose limit runs through very different
  third-party liquidity may revert and need another limit.
* The mock Baazaar's economics are a stand-in: anyone with a minted mock gotchi can list it at any price, the
  sink always buys the cheapest affordable one at or below `MAX_BUY_PRICE`, and a third party may add
  acquisitions to the escrow by buying their own listing for it (costing them the price and a commitment).
* Commit-reveal is a mock randomness source suitable for Sepolia demos only; the operator can steer it.

## Revision notes

This tree revises the accepted first delivery after an independent review. What changed, by finding:

* `MockBaazaar.cheapest()` scanned every listing ever created; it now scans an active-id index
  (swap-and-pop), so list/cancel cycles cannot strand the sink's ETH behind an unaffordable scan.
* The picker is versioned (OpenZeppelin `Checkpoints`); the escrow freezes `version()` at the request and
  resolves against it, so a registration or refresh after the roll becomes knowable cannot steer the winner.
* A `Pending` acquisition can bind a commitment made after its receipt (eligibility is "committed in an
  earlier block than the binding"), so `requestFlip` works and empty-queue purchases are no longer guaranteed
  burns.
* ETH-specified swaps are charged 30 bps of the ETH that actually fills (sized from the price limit, verified
  in `afterSwap`), so a partial fill no longer overcharges or leaves an ETH buyer paying ETH.
* The operator's real powers under the mock (grinding, selective reveal) are documented in NatSpec and here.
* The hook, FeeSink, ForeverLiquidity and pool initialization are created in one transaction by
  `GotchiStackDeployer`; the initial liquidity uses an exact price band; the script runs with `--slow`.
* Stale sybil entries are re-drawn past and refreshed away by `drawAt`; the registry has no capacity cap;
  `FeeSink.MAX_BUY_PRICE` caps what one purchase pays; stray ETH to the Baazaar is refused; stray NFTs in the
  escrow can be swept; `sqrtPriceX96ForAmounts` reverts cleanly instead of panicking.
* Not changed, by design: `FeesCollected.pool` (see Events), hook address validation in the constructor
  (see GotchiFeeHook), and the escrow's inability to distinguish a third party's self-purchase from the
  sink's (see MockBaazaar).

## TODO (out of scope for this job)

* Base deployment / Base cutover of the pool and hook.
* Aavegotchi Diamond and live Baazaar integration (replace `MockAavegotchi` / `MockBaazaar`; the
  `IBaazaarBuyer` callback purchase would become a real Baazaar `executeERC721Listing` call paid in GHST).
* Chainlink VRF (Sepolia coordinator + subscription) replacing the commit-reveal operator in `FlipEscrow`;
  keep the `FlipRequested(requestId)` / `FlipResolved` events so the UI does not change.
* Independent adversarial review before anything holding third-party funds goes live.

## Licences

Project code: MIT. Vendored: forge-std (MIT/Apache-2.0), OpenZeppelin Contracts (MIT), Uniswap v4-core
(MIT libraries and interfaces; `PoolManager` under BUSL-1.1, used here as a test dependency and deployed on
Sepolia by Uniswap), solmate `Owned` (AGPL-3.0, test dependency of `PoolManager`).
