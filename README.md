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
| `src/HookFlags.sol`, `src/HookMiner.sol` | hook permission bits and CREATE2 salt mining |
| `script/DeployGotchiSepolia.s.sol` | optional Sepolia deploy of everything + pool init + initial liquidity |
| `abi/*.json` | exported ABIs for the eight contracts (`forge inspect <Name> abi --json`) |
| `test/*.t.sol` | 107 tests, see "Tests" |
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
for c in LaunchToken GotchiFeeHook FeeSink MockAavegotchi MockBaazaar FlipEscrow HolderWeightedPicker ForeverLiquidity; do
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
| `FLIP_BURN_BPS` | 5000 (50%) | `FlipEscrow` |
| `BURN_ADDRESS` | `0x000000000000000000000000000000000000dEaD` | `FlipEscrow`, `HolderWeightedPicker` |
| Reveal window / pending timeout | 7,200 blocks each (~1 day on Sepolia) | `FlipEscrow` |
| Max active listings | 128 | `MockBaazaar` |
| Picker capacity | 65,536 registered holders | `HolderWeightedPicker` |
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
`FlipEscrow.AcquisitionReceived / RandomnessCommitted / FlipRevealed / FlipExpired`,
`HolderWeightedPicker.HolderRegistered / WeightRefreshed`, `ForeverLiquidity.LiquidityLocked`.

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
* Fee mechanics. ETH is currency0 in every native pool. When ETH is the *specified* amount (exact-input
  ETH sale, exact-output ETH purchase) `beforeSwap` returns a positive specified delta equal to
  `FEE_BPS` of `|amountSpecified|`; when ETH is the *unspecified* amount `afterSwap` returns a positive
  unspecified delta equal to `FEE_BPS` of the ETH the swap moved. In both cases `afterSwap` immediately
  `take`s the credited ETH out of the PoolManager **to the FeeSink** (the PoolManager pays the sink
  directly; the hook never holds ETH or tokens and no `call{value}` lives in the hook).
  Non-ETH pools using the hook pay no fee; an ETH pool pays no fee until a sink is bound.
* Wiring: `feeSink` is zero at construction. The FeeSink's constructor calls `bindFeeSink()`, which sets
  `feeSink = msg.sender` **once**; there is no setter, owner or way to redirect fees afterwards (no hidden
  treasury). Deploy the sink right after the hook (the script does, and asserts the binding; a factory
  deploying both in one transaction cannot be front-run).
* Address flags are **not** validated in the constructor (a factory picks its own CREATE2 salt). The deploy
  script mines a salt so the address carries exactly `0xCC` and asserts `addressHasValidFlags()`. A hook at
  an address without those bits is inert: the PoolManager either refuses to initialize a pool with it or
  calls callbacks that revert. Redeploy in that case.

### FeeSink

* `receive()` accepts ETH from anyone (the PoolManager for fees, donations otherwise), records
  `totalCollected` and emits `FeesCollected(msg.sender, amount)`.
* `triggerBuy()` is a **permissionless crank**: reverts `BelowThreshold` under 0.01 ETH, `NoListing` when
  the Baazaar is empty, `CannotAfford` when the cheapest listing costs more than the balance. Otherwise it
  arms `pendingPayment = price`, emits `BuyTriggered`, calls `MockBaazaar.buyCheapest(escrow, price)` and
  verifies the listing/token/price it got back and that the payment was collected. The buy is not run inside
  the swap on purpose: swaps stay cheap and marketplace state can never block trading. A keeper, the UI or
  anyone else calls the crank; `canBuy()` says whether it would succeed and what it would buy.
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
  active listings). `cancel` returns it to the seller. `cheapest()` scans active listings: lowest price,
  ties to the oldest id.
* `buyCheapest(recipient, maxPrice)` works two ways: with `msg.value` (excess refunded) for wallets, or with
  `msg.value == 0` for contracts implementing `IBaazaarBuyer` (the Baazaar calls `payForListing` and checks
  its own balance grew by the price). The NFT is `safeTransferFrom`'d to `recipient`.
* Sellers are paid by **pull** (`proceeds`, `withdrawProceeds`), so a seller that reverts on ETH can never
  block a purchase. No admin role.

### FlipEscrow

* Only accepts NFTs delivered by the configured NFT contract **from the Baazaar** (i.e. purchases). Each
  delivery becomes an acquisition (`AcquisitionReceived`).
* Randomness is a **commit-reveal mock**. The `OPERATOR` queues `keccak256(abi.encodePacked(secret))`
  commitments (`commit`, `commitMany`). An acquisition binds to the oldest unused commitment that was made
  in an earlier block than the NFT's arrival (`FlipRequested`, `requestId` =
  `keccak256(escrow, chainId, acquisitionId, tokenId, commitmentIndex, hash)`). Anyone who knows the secret
  calls `reveal`: `roll = keccak256(secret, requestId)`; `roll % 10_000 < 5_000` burns, otherwise the
  picker chooses the recipient. No eligible holder, or a stale winner weight, falls back to a burn.
* Forced burns: a bound acquisition whose secret is not revealed within `REVEAL_WINDOW_BLOCKS`, or a
  `Pending` one that never got a commitment within `PENDING_TIMEOUT_BLOCKS`, can be `expire`d by anyone
  and is burned (`FlipExpired`, `FlipResolved(burned = true)`).
* Resolution order is effects → events → one `transferFrom` (not `safeTransferFrom`, so a recipient that
  cannot receive NFTs can never block the pipeline).
* Limitations (documented, inherent to the mock): once the operator knows a request id they can predict
  the outcome, and they can refuse to reveal, which only ever produces a burn. Chainlink VRF on Sepolia
  was not wired because no subscription/keys are available in this job; see TODOs.

### HolderWeightedPicker

* **Opt-in registry.** A holder calls `register()` for themselves (so nobody can enter a contract such as
  the launch distributor, a vesting wallet or a Safe without its consent). Registration stores the current
  balance as the weight. Excluded forever: the zero address, the dead address, the PoolManager (it
  custodies the pool's tokens) and the picker itself. Zero balances cannot register and carry zero weight.
* **Snapshot weighting with live confirmation.** Weights are the balance as of each holder's last
  `refresh(holder)` (anyone may refresh anyone). `pick(randomness)` selects `randomness % totalWeight` over a
  Fenwick tree (O(log n), deterministic, no loops over external calls) and then reads the winner's **live**
  balance once: if it is below the stored weight the pick forfeits (→ burn). This blocks "refresh then move
  the tokens elsewhere" double counting; it also means a holder who sold since their last refresh should be
  refreshed before reveals. A UI/keeper should refresh registered holders ahead of each reveal.
* `Airdropped.weight` is the stored weight the winner was selected with.
* No admin role; the exclusion list is fixed at construction.

### ForeverLiquidity (the simple/forever pool)

* Defines the pool key: ETH / GOTCHI, LP fee 0, tick spacing 60, this project's hook. With an LP fee of
  zero the hook's 0.30% ETH skim is the whole trading fee and no LP fee ever accrues to the position (no
  hidden treasury; asserted in tests).
* `initializePool(sqrtPriceX96)` (anyone, once — the PoolManager refuses a second call) and
  `addLiquidity(liquidity, maxTokens)` payable (anyone). The contract owns the single full-range position;
  **there is no function to remove liquidity, collect or transfer the position**. Unused ETH/tokens are
  refunded; the contract never keeps a balance.
* Tokens are pulled from `msg.sender` only (never from a stored payer), and the contract pays the
  PoolManager from its own balance inside `unlockCallback`, which only the PoolManager can call.
* Quoting helpers: `sqrtPriceX96ForAmounts`, `liquidityForAmounts`, `amountsForLiquidity` (uses the
  pool's own rounding; the callback checks the PoolManager asked for exactly the quoted amounts).

## Admin roles and trust assumptions

| Contract | Role | Power | Cannot |
|---|---|---|---|
| LaunchToken | none | — | mint, pause, block, tax, upgrade |
| GotchiFeeHook | none (one-time self-binding by the FeeSink) | — | change fee, redirect fees, pause, gate pools |
| FeeSink | none | — | withdraw, redirect, change threshold |
| MockAavegotchi | `MINTER` (immutable) | mint mock gotchis for demo listings | burn, pause, move others' tokens |
| MockBaazaar | none | — | delist/reprice others, take proceeds |
| HolderWeightedPicker | none | — | edit weights or exclusions |
| FlipEscrow | `OPERATOR` (immutable) | queue randomness commitments; withhold a reveal (→ burn) | choose a winner, move an NFT, skip a burn |
| ForeverLiquidity | none | — | remove liquidity, collect fees |

Nothing is upgradeable, nothing uses `delegatecall` or `selfdestruct`, there is no post-deploy mint and no
fee treasury other than the FeeSink, whose only outflow is the Baazaar purchase. The operator and minter
are trusted only for liveness and demo inventory. Passing tests are not an audit: an independent
adversarial review is still required before anything holding third-party funds goes live.

## Static-analysis notes

The previous attempt at this job was rejected by static analysis. This rewrite designs those findings out:

* no `transferFrom`/`safeTransferFrom` with a stored or caller-supplied `from` (always `msg.sender` or
  `address(this)`);
* every `call{value}` is either gated by a `msg.sender` check (`FeeSink.payForListing`,
  `ForeverLiquidity.unlockCallback`), a refund of `msg.value` (`MockBaazaar.buyCheapest`,
  `ForeverLiquidity.addLiquidity`) or a `proceeds[msg.sender]` withdrawal; the hook moves ETH only through
  `PoolManager.take`;
* no strict equality on balances, `balanceOf` results or block numbers; no `block.timestamp` anywhere
  (windows are in blocks); no `blockhash`/`prevrandao` in the roll;
* no external calls inside loops (the picker is a Fenwick tree, the Baazaar scan touches storage only);
* every local is initialized, every external return value is captured, state and events come before
  external calls, and every state-changing entry point with an external call is `nonReentrant`.

Slither could not be run on the build machine (no `pip`); `forge build` lints were reviewed and the
remaining ones are informational (`unsafe-typecast` after range checks, `require-revert-in-loop` in
`commitMany`, lint-level `reentrancy-balance` on the intended before/after balance check in
`buyCheapest`).

## Tests (107)

| Suite | Covers |
|---|---|
| `LaunchToken.t.sol` | supply, decimals, transfer exactness, no admin/mint selectors, no escape opcodes |
| `GotchiFeeHook.t.sol` | flags = v4-core constants, address validity, one-time binding, **fee in all four swap directions vs an un-hooked reference pool**, accumulation, rounding, no fee unbound / on token-token pools, caller gating, disabled callbacks |
| `FeeSink.t.sol` | receive + event, **threshold/no-listing/unaffordable no-buy**, successful buy (seller credit, escrow custody, counters), repeat buys, payment callback gating, **reentrancy from a malicious marketplace** |
| `MockBaazaar.t.sol` | minter role, list/cancel/cap, **cheapest selection and tie-break**, value and callback purchases, refunds, unpaid revert, **pull payments and a seller that rejects ETH** |
| `HolderWeightedPicker.t.sol` | exclusions, zero balance, double registration, refresh up/down, **deterministic range selection**, forfeit on stale weight, zero-weight holders never win, fuzz |
| `FlipEscrow.t.sol` | operator gating, intake gating, commitment eligibility and FIFO binding, **burn path, airdrop path**, no-eligible-holder and stale-winner burns, bad secret, window close, **forced burn on withheld reveal and on pending timeout** |
| `ForeverLiquidity.t.sol` | key/constants, seeded position, double init, price math, quoting, add with refunds, underfunding, callback gating, no removal path, no LP fee accrual |
| `EndToEnd.t.sol` | **swaps → fees → buy → flip (burn and airdrop) with the full event trail**, below-threshold no-buy in the middle, conservation of ETH, forced-burn variants |
| `DeployScript.t.sol` | the script's `deploy(Config)` against a local PoolManager: wiring, mined hook address, pool price/liquidity, supply |
| `ProjectFloor.t.sol` | constructors against the literal Sepolia PoolManager leave the supply untouched, EIP-170 size, no DELEGATECALL/CALLCODE/SELFDESTRUCT |

## Deployment (optional, Sepolia)

```
forge script script/DeployGotchiSepolia.s.sol --rpc-url $SEPOLIA_RPC                      # simulate
forge script script/DeployGotchiSepolia.s.sol --rpc-url $SEPOLIA_RPC --broadcast --verify  # deploy
```

Environment (all optional): `GOTCHI_OPERATOR`, `GOTCHI_MINTER` (default: the broadcaster),
`GOTCHI_INITIAL_ETH` (default 0.1 ether), `GOTCHI_INITIAL_TOKENS` (default 100,000,000 GOTCHI).

What `run()` does, in order: refuses any chain but Sepolia; deploys `LaunchToken` (supply to the
broadcaster); mines a CREATE2 salt through the canonical deployer `0x4e59b44847b379578588920cA78FbF26c0B4956C`
so the hook address carries `0xCC` and deploys `GotchiFeeHook(0xE03A…3543)`; deploys `MockAavegotchi`,
`MockBaazaar`, `HolderWeightedPicker`, `FlipEscrow`, `FeeSink` (which binds itself to the hook; the script
asserts it) and `ForeverLiquidity`; initializes the pool at the price implied by the two liquidity amounts
and adds them as forever liquidity. It logs every address and the salt. Redeploying skips salts whose
address already has code.

Deployment order / constructor arguments, for a factory or manifest:

| # | Contract | Constructor args |
|---|---|---|
| 0 | `LaunchToken` | — |
| 1 | `GotchiFeeHook` | `0xE03A1074c86CFeDd5C142C4F04F1a1536e203543` (CREATE2 salt must give an address with low 14 bits `0xCC`) |
| 2 | `MockAavegotchi` | minter address |
| 3 | `MockBaazaar` | `MockAavegotchi` |
| 4 | `HolderWeightedPicker` | `LaunchToken`, PoolManager |
| 5 | `FlipEscrow` | `MockAavegotchi`, `MockBaazaar`, `HolderWeightedPicker`, operator address |
| 6 | `FeeSink` | `GotchiFeeHook`, `MockBaazaar`, `FlipEscrow` (must follow the hook immediately; binds itself) |
| 7 | `ForeverLiquidity` | `LaunchToken`, PoolManager, `GotchiFeeHook` |

All constructors are nonpayable with address-only arguments and make no supply-moving calls. If a launch
factory deploys these, note that its own token pool (with its own guard hook) is a different pool from
the ETH/$GOTCHI hook pool described here; the fee hook applies only to pools initialized with
`ForeverLiquidity.poolKey()` (or any other native-ETH pool someone initializes with this hook).

### Operational responsibilities

* **Broadcaster**: funds `GOTCHI_INITIAL_ETH` plus gas, receives the token supply, verifies sources on
  the explorer (`forge verify-contract`), checks `hook.feeSink() == sink` and `hook.addressHasValidFlags()`
  after deployment (redeploy if either fails).
* **Operator** (`FlipEscrow.OPERATOR`): keeps a buffer of commitments queued *ahead* of purchases
  (`commitMany`), stores the secrets safely, reveals within 7,200 blocks. A missed reveal or an empty queue
  turns the flip into a burn; it never turns into a theft.
* **Minter** (`MockAavegotchi.MINTER`): mints demo gotchis and lists them (`approve` + `list`) so the sink
  has something to buy.
* **Keepers / UI**: call `FeeSink.triggerBuy()` when `canBuy()` is true, `FlipEscrow.requestFlip` for
  pending acquisitions once commitments exist, `HolderWeightedPicker.refresh` for registered holders before
  reveals, and `FlipEscrow.expire` for stuck ones. All of these are permissionless.
* **Holders**: `register()` once to be eligible for airdrops; refresh after balance changes.
* **Sellers**: `withdrawProceeds()` to collect ETH from sales.

## Assumptions

* The Sepolia PoolManager at `0xE03A1074c86CFeDd5C142C4F04F1a1536e203543` is the Uniswap v4 singleton with
  the v4-core 1.0.2 interface vendored here; the tests run against a locally deployed copy of that code.
* Native ETH is currency0 of the pool, so "ETH side" always means `amount0`.
* Fees are taken only on swaps (not on liquidity changes or donations), only on native-ETH pools, and only
  once a sink is bound.
* The mock Baazaar's economics are a stand-in: anyone with a minted mock gotchi can list it at any price and
  the sink always buys the cheapest affordable one.
* Commit-reveal is a mock randomness source suitable for Sepolia demos only.

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
