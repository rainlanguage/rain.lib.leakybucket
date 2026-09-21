# rain.lib.leakybucket

A leaky bucket rate limiter for Solidity, as pure functions.

Built for capping mints on a token, which is security critical and on the hot
path of every mint, so the whole library is two files, both `internal`, both
`pure`, with no storage, no owner and no governance of its own.

## The model

The bucket holds a `level`. Filling adds to the level and is rejected if the
level would pass `capacity`. The level leaks away continuously at `leakRate`
units per second and stops at zero. That is the whole thing.

Two numbers describe a policy:

- **`capacity`** — the burst. The most that can be minted in one block, and the
  most that can ever be outstanding against the cap at one instant.
- **`leakRate`** — the sustained rate, in units per second.

Together they give the standard leaky bucket bound, for any interval of
`elapsed` seconds:

```
minted(elapsed) <= capacity + elapsed * leakRate
```

The bound is tight. Someone holding a full bucket can wait one drain time
(`capacity / leakRate` seconds) and burst again, extracting `2 * capacity`
across that window. **A leaky bucket is a burst-plus-rate bound, not a rolling
window cap.** Sizing `capacity` is a security decision: it is the number that
has to be survivable on its own if a minter is compromised at the moment the
bucket is full.

## Usage

The state is one `uint256` per bucket. A zero word is an empty bucket
checkpointed at the epoch, so an untouched storage slot is already a valid
starting state and no initializer is needed.

```solidity
import {LibLeakyBucketCheckpoint} from "rain-lib-leakybucket-x.y.z/src/lib/LibLeakyBucketCheckpoint.sol";

contract Token {
    mapping(address minter => uint256 checkpoint) internal sBuckets;
    mapping(address minter => uint256 capacity) internal sCapacity;
    mapping(address minter => uint256 leakRate) internal sLeakRate;

    function mint(address to, uint256 amount) external {
        sBuckets[msg.sender] = LibLeakyBucketCheckpoint.fill(
            sBuckets[msg.sender], block.timestamp, sCapacity[msg.sender], sLeakRate[msg.sender], amount
        );
        _mint(to, amount);
    }
}
```

One `SLOAD`, one library call, one `SSTORE`. The call reverts with
`LeakyBucketCapacityExceeded(capacity, level, amount)` if the amount does not
fit, and nothing is written.

### Governance is yours

`capacity` and `leakRate` are arguments on every call, never library state. The
library is reached identically from immutables, a timelocked setter, a staged
upgrade, a governor, or a per minter mapping holding a different pair for every
minter. It has no opinion about ordering, delay or authority, which is what lets
it sit under any of them unchanged.

Two properties make policy changes safe to land at an arbitrary moment:

- **Lowering `capacity` below an outstanding level binds immediately.** Headroom
  reads zero, every non zero fill is rejected, and the bucket leaks down under
  the new policy until it fits. No migration, no fill needed to activate it, and
  no window for the minter to front run the change.
- **An unconfigured minter can mint nothing.** A zero capacity is a closed door,
  so forgetting to configure a minter fails closed.

### Reading without filling

- `headroomAt` — what would fit right now.
- `levelAt` — what is outstanding right now.
- `fillableAt` — the earliest second a given amount would fit, or
  `type(uint256).max` for never. A view for callers and frontends; nothing in
  the enforcement path consults it.

### The pure core

`LibLeakyBucketCheckpoint` is the packed convenience layer over
`LibLeakyBucket`, which takes `(level, checkpoint)` as separate arguments and
imposes no encoding at all. Use it directly if the packed widths do not suit,
for example to keep the level in a wider field, or to hold bucket state
somewhere other than a storage word.

Be aware of what the codec is protecting against if you do.
`LibLeakyBucket.fillAt` returns a level belonging to the timestamp it was
evaluated at; storing that level while leaving the old checkpoint timestamp in
place credits the same leak again on the next call and the cap quietly stops
binding. It is a one line mistake with no symptom until it is exploited. The
codec returns the level and the timestamp as one word so there is no second
write to forget.

## Design notes

### Seconds, not blocks

Time is `block.timestamp`, in seconds. Block numbers appear nowhere. Block times
differ by an order of magnitude between chains and change under the same chain
over time, so a cap expressed in blocks is a different cap on every deployment
and silently becomes a different cap after a hard fork. The same `capacity` and
`leakRate` deploy unchanged anywhere.

### No checkpoint drift

The leak is `elapsed * leakRate` computed from the checkpoint in one multiply,
so checkpointing more often cannot change the result:

```
levelAt(levelAt(level, t0, t1, rate), t1, t2, rate) == levelAt(level, t0, t2, rate)
```

for any `t0 <= t1 <= t2`. Exactly, at every input, with no rounding slack. It is
fuzzed over the unbounded input space, and it is also checked end to end through
storage: a half hour taken in one step lands on the same level as the same half
hour taken a second at a time with a write every second.

This is worth stating because the usual alternative does not have it.
Implementations that store a `window` and leak at `capacity / window` per second
take a floor division on every checkpoint, so each call discards the sub unit
remainder, and a caller touching the bucket every second is credited measurably
less leak than one touching it hourly. That makes call frequency part of the
cap. Here the rate is a parameter rather than a quotient, so there is no per
call remainder to lose.

The cost is that `leakRate` is per second, so a policy written as "X per day" is
`X / 86400` and is rounded once, off chain, where the rounding is deliberate and
visible. Round down, so the on chain rate is never faster than the policy.

### Arithmetic, and which way it fails

Every operation that could leave the representable range is a saturating one
from
[`rain.math.saturating`](https://github.com/rainlanguage/rain.math.saturating)
(audited by Protofire, January 2026, same licence as this library). There is no
hand rolled overflow guard here to review. The directions are chosen so the
failure mode is always a tighter cap or a drained bucket, never free headroom:

| Operation                | Saturates              | Because the alternative is                                       |
| ------------------------ | ---------------------- | ---------------------------------------------------------------- |
| `elapsed * leakRate`     | at `type(uint256).max` | a wrapped product is a _small_ leak, which is free headroom      |
| `level - leaked`         | at zero                | a drain past empty underflows to an enormous level               |
| `timestamp - checkpoint` | at zero                | a clock behind the checkpoint wraps to billions of years of leak |
| `capacity - level`       | at zero                | a level above capacity underflows to an enormous allowance       |

A clock at or behind the checkpoint therefore credits **no leak**, rather than
reverting or wrapping. Reverting would let a backwards clock brick minting until
it caught up; wrapping would empty the bucket outright. Crediting nothing can
only ever report a level at or above the true level, so it can only ever hand
out _less_ headroom than reality.

The packed codec **reverts** rather than truncating on an oversized level or
timestamp. A truncated time field reads as a checkpoint in the distant past,
which is an enormous leak, which is a full bucket of headroom nobody waited for.
Failing closed at an unreachable date beats failing open at a reachable one.

### Storage layout

One word: the level in the high 192 bits, the timestamp in the low 64.

| Field       | Width    | Max                                            |
| ----------- | -------- | ---------------------------------------------- |
| `level`     | 192 bits | ~6.2e57, or 6.2e39 whole tokens at 18 decimals |
| `timestamp` | 64 bits  | ~5.8e11 years                                  |

`unpack` is total, so any word in the space reads as some valid bucket.
Governance should reject a `capacity` above `LEAKY_BUCKET_LEVEL_MAX` when it is
set, rather than discovering it at mint time.

## Gas

Measured by `test/src/lib/LibLeakyBucketGas.t.sol`, which asserts a band around
each figure so a compiler or EVM change that moves one fails the suite.

| Path                              | Gas    |
| --------------------------------- | ------ |
| Steady state fill (non zero slot) | 8,845  |
| First fill (zero slot)            | 23,433 |
| Rejected fill                     | 8,122  |

Against the same bucket held in two slots instead of one: **2,025** saved on the
extra cold `SLOAD` in the steady state, and **21,925** on the extra `SSTORE` for
a first fill. The two are measured separately because `forge` carries its dirty
slot journal across from `setUp`, so a single steady state measurement cannot
price the second `SSTORE`.

## Why this exists

Nothing off the shelf was audited, openly licensed _and_ a contract agnostic
library at the same time, as at September 2026:

| Candidate                                                                                                                            | Licence                                         | Audited                                                                    | Fit                                                                                                   |
| ------------------------------------------------------------------------------------------------------------------------------------ | ----------------------------------------------- | -------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------- |
| [OpenZeppelin 5.7 `RateLimiter`](https://github.com/OpenZeppelin/openzeppelin-contracts/blob/master/contracts/utils/RateLimiter.sol) | MIT                                             | **No** — OZ's `audits/` stops at v5.6 (Feb 2026); this file is new in v5.7 | One shared `capacity`/`window` for every key, so it cannot express per minter caps of different sizes |
| [Lombard `RateLimitsV2`](https://github.com/lombard-finance/evm-smart-contracts/blob/main/contracts/libs/RateLimitsV2.sol)           | MIT header, but **no LICENSE file in the repo** | Yes (OpenZeppelin)                                                         | `uint32` timestamp **fails open** after 2106; `public`, so it needs linking                           |
| [Chainlink CCIP `RateLimiter`](https://github.com/smartcontractkit/chainlink-ccip)                                                   | **BUSL-1.1**                                    | Yes                                                                        | Licence rules it out                                                                                  |
| [Hyperlane `RateLimited`](https://github.com/hyperlane-xyz/hyperlane-monorepo/blob/main/solidity/contracts/libs/RateLimited.sol)     | MIT OR Apache-2.0                               | Partial                                                                    | An `OwnableUpgradeable` **contract** with governance built in, not a library                          |

## Audit scope

Not yet audited. The intended scope is `src/`, which is two files and no
dependencies beyond `LibSaturatingMath`, itself already audited. The properties
an audit should hold the implementation to are the ones fuzzed in
`test/src/lib/`:

- The bound `minted(elapsed) <= capacity + elapsed * leakRate` holds under
  arbitrary splits of the calls and arbitrary gaps between them.
- Leaking never raises the level, at any input.
- Exactly the reported headroom fits and one unit more does not.
- Checkpointing changes nothing.
- Every saturation goes the conservative way, per the table above.
- The packed codec round trips, is total on `unpack`, does not alias its fields,
  and reverts rather than truncating.

`test/lib/LibLeakyBucketSlow.sol` is the differential oracle: the same leak
written as a one-second-at-a-time loop, which the closed form is checked
against.

## Development

```
nix develop
forge test
```
