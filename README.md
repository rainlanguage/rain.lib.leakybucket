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

- **`capacity`** — the burst. The most that can be minted in one transaction,
  and the most that can ever be outstanding against the cap at one instant.
- **`leakRate`** — the sustained rate, in units per second.

### Before a mint, and after it

The burst is the security-critical constraint, and the two sides of a mint are
deliberately not symmetric.

**Before a mint, the burst is capped at `capacity`. Always.** However long the
bucket has been sitting untouched, the most a single mint can take is one
`capacity`. Elapsed time cannot enlarge a burst. The leak credited before a mint
is `min(level, elapsed * leakRate)` — bounded by the level, which is bounded by
`capacity` — and the level stops at zero rather than going negative, so idling
banks no credit. Idle for an hour or for a decade and the answer is the same:
one `capacity`, never more.

**Immediately after a mint consumes the bucket, it is zero.** At that same
second, not at the next block and not partially. What was available has been
spent, and nothing is available again until time passes.

**Then it refills by leaking, up to `capacity` and no further.** The refill is
what `leakRate` sets the pace of, and it is bounded by `capacity` as well: the
bucket cannot refill past full, so the next burst is capped at `capacity`
exactly as the first one was.

That asymmetry is the security property in one line: **no burst, at any point in
the bucket's history, can exceed `capacity`.** What `leakRate` controls is how
often a burst can be repeated, never how large one can be.

So sizing `capacity` is a security decision rather than a convenience: it is the
number that has to be survivable on its own, because it is the most a minter can
take in one go if it is compromised at the worst moment.

These bounds are fuzzed over the unbounded input space in
`test/src/lib/CapacityBound.t.sol`, not merely checked on a worked example.

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

The one bound the codec does impose is an upper one, because it follows from the
packing rather than from any policy view: a `capacity` above
`LEAKY_BUCKET_LEVEL_MAX` is a cap the one word layout cannot enforce, and every
packed call that takes a `capacity` reverts `LeakyBucketCapacityOverflow` rather
than half enforcing it. `LibLeakyBucketCheckpoint.checkCapacity` is the same
guard on its own, so a setter can refuse the policy at the moment it is set:

```solidity
function setCapacity(address minter, uint256 capacity) external onlyGovernance {
    LibLeakyBucketCheckpoint.checkCapacity(capacity);
    sCapacity[minter] = capacity;
}
```

### Reading without filling

- `headroomAt` — what would fit right now.
- `levelAt` — what is outstanding right now.
- `fillableAt` — the earliest second a given amount would fit, or
  `type(uint256).max` for never. A view for callers and frontends; nothing in
  the enforcement path consults it.

`headroomAt` is exactly what `fill` takes: the amount it names always fits, and
one unit more is always rejected. `fillableAt` names a second at which the fill
it was asked about would be accepted. Neither answers at all for a `capacity`
the codec cannot enforce, because any answer there would be a promise `fill`
would break.

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

The other obligation a direct caller takes on is that **a stored checkpoint must
never move backwards.** A fill at a time at or behind the stored checkpoint
credits no leak, so the level it returns belongs to the checkpoint rather than
to the supplied time; writing the earlier second back leaves an interval that
has already been paid for to be measured again on the next read, which hands out
headroom nobody waited for. Store the later of the two. The codec does that
itself, so it is only a hazard for state held outside it.

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
([audited by Protofire, January 2026](https://github.com/rainlanguage/rain.math.saturating/blob/sol-v0.1.10/audit/protofire/rain.math.saturating.22e58d70a223b18d83dfc5529e3ac87aef3ff478.jan-2026.pdf),
covering commit `22e58d7`; same licence as this library). There is no hand
rolled overflow guard here to review. The directions are chosen so the failure
mode is always a tighter cap or a drained bucket, never free headroom:

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

The write path has to keep what the read path refuses. A fill at a backwards
clock stores **the later of that clock and the stored checkpoint**, never the
earlier: crediting no leak for the backwards step and then recording the earlier
second leaves the same interval to be measured again on the next read, which
pays out exactly the headroom the saturation just declined. That makes the
property above hold end to end and not only on a read, and it is what a caller
holding `(level, checkpoint)` outside the codec has to reproduce.

The packed codec **reverts** rather than truncating on an oversized level or
timestamp. A truncated time field reads as a checkpoint in the distant past,
which is an enormous leak, which is a full bucket of headroom nobody waited for.
Failing closed at an unreachable date beats failing open at a reachable one.

It reverts on an unenforceable `capacity` for the same reason and with the same
preference for failing loudly: a capacity above `LEAKY_BUCKET_LEVEL_MAX` permits
a level the word cannot hold, so clamping it would enforce a policy nobody set
and leaving it would have `headroomAt` name an amount `fill` refuses. Both are
worse than refusing the parameter and saying which one it was.

### Storage layout

One word: the level in the high 192 bits, the timestamp in the low 64.

| Field       | Width    | Max                                            |
| ----------- | -------- | ---------------------------------------------- |
| `level`     | 192 bits | ~6.2e57, or 6.2e39 whole tokens at 18 decimals |
| `timestamp` | 64 bits  | ~5.8e11 years                                  |

`unpack` is total, so any word in the space reads as some valid bucket.

`LEAKY_BUCKET_LEVEL_MAX` is therefore the widest `capacity` the codec can
enforce, and every packed call that takes a `capacity` rejects one above it with
`LeakyBucketCapacityOverflow(capacity)`. Governance should reject it at the
moment it is set as well, with `checkCapacity`, so the failure is a refused
policy change rather than a refused mint.

## Gas

Measured by `test/src/lib/LibLeakyBucketGas.t.sol`, which asserts a band around
each figure so a compiler or EVM change that moves one fails the suite.

| Path                              | Gas    |
| --------------------------------- | ------ |
| Steady state fill (non zero slot) | 8,923  |
| First fill (zero slot)            | 23,511 |
| Rejected fill                     | 8,188  |

Against the same bucket held in two slots instead of one: **1,947** saved on the
extra cold `SLOAD` in the steady state, and **21,847** on the extra `SSTORE` for
a first fill. The two are measured separately because `forge` carries its dirty
slot journal across from `setUp`, so a single steady state measurement cannot
price the second `SSTORE`.

The saving is the 2,100 of a cold `SLOAD` less the ~78 gas of the two guards the
codec runs and a two slot layout has no reason to: the bound on a `capacity` the
packed level field cannot hold, and the comparison that keeps the stored
checkpoint from moving backwards.

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
dependencies beyond `LibSaturatingMath`. That one is already audited, and the
reviewed artefact is the one this library compiles: Protofire reviewed
`rain.math.saturating` at commit `22e58d7` in January 2026, and
`src/lib/LibSaturatingMath.sol` is unchanged apart from comments between that
commit and the `0.1.10` the imports pin. The properties an audit should hold the
implementation to are the ones fuzzed in `test/src/lib/`:

- No burst can exceed `capacity`, at any point in a bucket history. `capacity`
  bounds the level, the headroom and any single fill at every instant, elapsed
  time never enlarges a single fill, and idling banks no credit however long it
  lasts. This is the security-critical property.
- A fill that consumes the bucket leaves zero headroom at that same second, and
  the refill afterwards is bounded by `capacity` as well.
- Leaking never raises the level, at any input.
- Exactly the reported headroom fits and one unit more does not.
- Checkpointing changes nothing.
- Every saturation goes the conservative way, per the table above.
- A stored checkpoint never moves backwards, so a fill at a stale clock is not
  observable at any later second.
- The packed codec round trips, is total on `unpack`, does not alias its fields,
  and reverts rather than truncating.
- The packed reads and `fill` agree at every input either will answer, and
  refuse the same capacities.

`test/lib/LibLeakyBucketSlow.sol` is the differential oracle: the same leak
written as a one-second-at-a-time loop, which the closed form is checked
against.

## Development

```
nix develop
forge test
```
