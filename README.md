# rain.lib.leakybucket

A leaky bucket rate limiter for Solidity, over a struct the caller stores.

Built for capping mints on a token, which is security critical and on the hot
path of every mint, so the whole library is one file exporting one struct,
`internal` functions over it and its errors, with no storage, no owner and no
governance of its own.

## The model

The bucket holds a `level`. Filling adds to the level and is rejected if the
level would pass `capacity`. The level leaks away continuously at `leakRate`
units per second and stops at zero. That is the whole thing.

Every number in a bucket is a `Float` from
[`rain.math.float`](https://github.com/rainlanguage/rain.math.float) — the
level, the capacity, the leak rate and the timestamp — so elapsed time is a
subtraction in the same arithmetic as the level rather than a separate fixed
point domain the caller converts across. Nothing is packed and nothing saturates
at a type boundary, because a `Float` has no boundary a bucket reaches. What is
left of the old saturation is the clamp at zero, which is a property of the
bucket rather than of the arithmetic: a leak never takes the level below zero,
and a clock behind the checkpoint credits no leak.

Two numbers describe a policy:

- **`capacity`** — the burst. The most that can be minted in one transaction,
  and, under an unchanged policy, the most that can be outstanding against the
  cap at one instant. Lowering `capacity` can leave more than that outstanding
  until it leaks down; see "Governance is yours" below.
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

**Immediately after a mint consumes the burst, the headroom is zero.** At that
same second, not at the next block and not partially. What was available has
been spent, and nothing is available again until time passes. The mint raised
the level; what it emptied is the headroom.

**Then the headroom returns by leaking, up to `capacity` and no further.** The
leak is what `leakRate` sets the pace of. What bounds the headroom it returns is
the floor under the level rather than a ceiling over it: the level clamps at
zero instead of going negative, and headroom is `capacity` less the level, so
the next burst is capped at `capacity` exactly as the first one was.

That asymmetry is the security property in one line: **no burst, at any point in
the bucket's history, can exceed `capacity`.** What `leakRate` controls is how
often a burst can be repeated, never how large one can be.

So sizing `capacity` is a security decision rather than a convenience: it is the
number that has to be survivable on its own, because it is the most a minter can
take in one go if it is compromised at the worst moment.

These bounds are fuzzed in `test/src/lib/CapacityBound.t.sol`, not merely
checked on a worked example. The fuzz draws whole numbers at exponent zero —
levels and capacities to `2**128`, times to `2**64`, leak rates to `2**128` —
which is what keeps its assertions exact rather than approximate. "Precision"
below says what lies outside those bounds and which tests go there.

## Usage

Install it with soldeer. The published package is `src/`, this README and the
licence files — no `foundry.toml` and no lock file — so nothing in it declares
the one dependency `src/` has, and installing this package on its own leaves an
unresolved import. Install both:

```
forge soldeer install rain-lib-leakybucket~x.y.z
forge soldeer install rain-math-float~0.2.4
```

`0.2.4` there is exact, not a floor. `src/lib/LibLeakyBucket.sol` imports
`rain-math-float-0.2.4/src/lib/LibDecimalFloat.sol` by that literal path, and
soldeer keys the remapping it generates on the installed directory name, so any
other revision of `rain-math-float` is remapped under a different prefix and the
import does not resolve.

A bucket is a `LeakyBucket`: the `level`, the `timestamp` that level was
recorded at, the `capacity` and the `leakRate` — four `Float`s, so four words.
Store one wherever a bucket is needed — a mapping by minter, a mapping by pair,
four slots — hand it to `fill`, and store the level and the checkpoint `fill`
returns. The library is `pure`; the storage is yours. A zero level at a zero
timestamp is an empty bucket at the epoch and a zero capacity is a closed door,
so an untouched mapping entry is already a valid bucket that can mint nothing,
and no initializer is needed.

```solidity
import {Float, LibDecimalFloat} from "rain-math-float-0.2.4/src/lib/LibDecimalFloat.sol";
import {LibLeakyBucket, LeakyBucket} from "rain-lib-leakybucket-x.y.z/src/lib/LibLeakyBucket.sol";

contract Token {
    mapping(address minter => LeakyBucket bucket) internal sBuckets;

    function mint(address to, uint256 amount) external {
        // The exponent is the caller's: `capacity` and `leakRate` are in
        // whatever units this is.
        Float amountFloat = LibDecimalFloat.packLossless(int256(amount), 0);
        Float timestamp = LibDecimalFloat.packLossless(int256(block.timestamp), 0);
        (Float level, Float checkpoint) = LibLeakyBucket.fill(sBuckets[msg.sender], timestamp, amountFloat);
        sBuckets[msg.sender].level = level;
        sBuckets[msg.sender].timestamp = checkpoint;
        _mint(to, amount);
    }
}
```

One library call, then two `SSTORE`s by the caller. The level and the second it
belongs to are two words now rather than one packed word, so both of them are
the caller's to write, and a caller that writes the level and not the checkpoint
leaves the interval before the fill to be measured a second time on the next
read — which credits leak the clock never paid for. `fill` returns the pair; the
caller stores both or stores neither.

It reverts, and the revert takes both stores with it, on:

| Error                                                  | When                                                                                       |
| ------------------------------------------------------ | ------------------------------------------------------------------------------------------ |
| `LeakyBucketCapacityExceeded(capacity, level, amount)` | the amount is more than the headroom at that second                                        |
| `LeakyBucketZeroAmount()`                              | the amount is zero                                                                         |
| `LeakyBucketNegativeAmount(amount)`                    | the amount is negative, which would drain the bucket and mint under a cap it never reached |
| `LeakyBucketNegativeCapacity(capacity)`                | the capacity is negative, so no fill could ever fit                                        |
| `LeakyBucketNegativeLeakRate(leakRate)`                | the leak rate is negative, so the bucket would fill as time passed                         |
| `LeakyBucketNegativeLevel(level)`                      | the stored level is negative, which reads as more headroom than the capacity               |
| `LeakyBucketNegativeTimestamp(timestamp)`              | the stored timestamp, or the one read or filled at, is negative                            |
| `LeakyBucketAmountNotCredited(level, amount)`          | the amount fits the headroom but does not raise the level, so it would charge nothing      |

The four negative-bucket errors are checked before the amount, and `levelAt`,
fill would. The leak is computed before the amount is looked at, so on a bucket
whose leak `rain.math.float` cannot represent every amount reverts with that
library's error. Every parameter in the errors above is amount reverts with that
library's error. Every parameter in the errors above is a `Float`, which the ABI
names as `bytes32`.

### Governance is yours

`capacity` and `leakRate` are fields of the caller's struct, read on every call,
never library state. Whatever writes them — a constructor, a timelocked setter,
a staged upgrade, a governor, or a per minter mapping holding a different pair
for every minter — the library is reached identically. It has no opinion about
ordering, delay or authority, which is what lets it sit under any of them
unchanged.

**Change a policy with `setPolicy`, never by writing a field.** The leak is
computed at read time as `elapsed * leakRate`, with the rate read at that
moment. A bucket records its level and when it was recorded, not the rate that
was in force, so writing a new `leakRate` alone re-rates the whole interval
since the checkpoint, not only the time after the change:

- Raising the rate hands out headroom neither policy earned. With `capacity` 100
  and `leakRate` 1, a minter fills to 100 at second 0. At second 10 the headroom
  is 10. Raise `leakRate` to 100 and in that same second the headroom reads 100,
  so the minter takes 200 in 10 seconds where the two policies allowed 110.
- `leakRate = 0` is not a pause. Elapsed time keeps accumulating while the rate
  is zero, and restoring the rate leaks all of it at once.
- Lowering the rate takes back leak the old rate had already paid.

The excess is bounded by the outstanding level, so it is never more than one
`capacity` and the burst bound above holds either way. What is lost is the
sustained rate.

`setPolicy` takes the bucket, the timestamp and the new `capacity` and
`leakRate`, and returns the whole bucket to store. It reverts on a negative
`capacity` or `leakRate` with the error `fill` would raise, zero passing; it
settles the level at the stored rate, so each rate is charged for the time it
was in force; and the bucket it returns carries the new policy from the later of
the timestamp and the stored one.

```solidity
function setPolicy(address minter, Float capacity, Float leakRate) external onlyGovernance {
    Float timestamp = LibDecimalFloat.packLossless(int256(block.timestamp), 0);
    sBuckets[minter] = LibLeakyBucket.setPolicy(sBuckets[minter], timestamp, capacity, leakRate);
}
```

`settle` on its own is the plain checkpoint: the level at the stored rate and
the later of the timestamp and the stored one, with nothing filled and no policy
changed.

A `capacity` change goes through `setPolicy` as well, with the `leakRate`
unchanged. Two properties make it safe to land at an arbitrary moment:

- **Lowering `capacity` below an outstanding level binds immediately.** Headroom
  reads zero, every fill is rejected, and the bucket leaks down under the new
  policy until it fits. No migration and no fill is needed to activate it, so
  between the write landing and the new cap binding there is no window for a
  minter to slip through.

  That is the only window this library closes. The window _before_ the write is
  governance's, and it is real: a cut queued behind a public timelock is visible
  for the whole delay, and a minter that is already compromised can take one
  full **old** `capacity` per burst, paced by the old `leakRate`, right up to
  the block the cut executes. A cut is usually incident response against
  precisely that minter, so size the delay on the assumption that the minter
  keeps drawing at the old policy for its whole length, or keep a pause or
  revoke path that does not sit behind the same delay.
- **An unconfigured minter can mint nothing.** A zero capacity is a closed door,
  so forgetting to configure a minter fails closed.

There is no upper bound on a policy any more. The old one came from the packing
rather than from any policy view — a `capacity` above `LEAKY_BUCKET_LEVEL_MAX`
was a cap the one word layout could not enforce, so both entry points refused it
with `LeakyBucketCapacityOverflow`, and the constant was exported so a setter
could refuse such a policy at the moment it was set. A `Float` capacity has no
ceiling to exceed, and `test/src/lib/LibLeakyBucket.t.sol` walks the coefficient
over its whole range and the exponent from `-1000` to `1000` to pin that every
non-negative capacity in that space is accepted, whatever its magnitude and
scale. A separate test fills a capacity of `1e60` — a level the packed word
could not have held at all — to the last unit and rejects the unit after it.

What is refused instead is the sign, on both policy fields, because neither
negative is a stricter bucket: a negative `capacity` admits no fill at all, and
a negative `leakRate` fills the bucket as time passes, which is the opposite of
a leak. `levelAt`, `headroomAt`, `settle` and `fill` refuse them by name on a
stored bucket, and `setPolicy` refuses them before they are stored.

### Reading without filling

`headroomAt` and `levelAt` read a bucket without filling it, and each is
exported for a reason of its own.

`headroomAt` is there because **a caller metering one amount through several
buckets cannot otherwise say which of them refused it.** `fill` reverts with
`LeakyBucketCapacityExceeded(capacity, level, amount)`, which names a policy and
a state but not a bucket, and two buckets can be running the same `capacity`.
`fill` is `internal`, so the revert cannot be caught and relabelled in the frame
that raised it. A caller that must attribute the rejection — a token metering
every mint through a global bucket and a per minter one, where "which cap bound"
decides whether an operator raises a limit or revokes a key — therefore has to
ask before it fills, and this is the question. Computing it outside the library
instead means re-deriving the leak and the clamp directions outside the library
that exists to hold them.

What it answers is the most `fill` takes: a positive answer always fits in full,
any amount above the answer is always rejected, and the two are guarded by the
same domain check and computed through the same arithmetic, so they agree at
every input by construction. A zero answer means nothing fits, and it is the one
answer that cannot be handed on: `fill` accepts only positive amounts and
refuses zero with `LeakyBucketZeroAmount`, so a caller checks the answer for
zero before filling. Neither answers at all for a negative `capacity` or a
negative `leakRate`, because any answer there would be a promise `fill` breaks.

`levelAt` is there because **it cannot be derived from `headroomAt`.**
`capacity - headroom` agrees with the level only while the level is at or under
the capacity. The headroom clamps at zero, so once a capacity is lowered under
an outstanding level that subtraction returns the capacity and silently
under-reports what is owed — which is exactly the state a capacity cut leaves
behind. A caller that wants the level has to be given it, so it is given it.

`headroomAt` is the capacity less what `levelAt` reports, clamped at zero, so
the two agree on every bucket at or under its capacity.
`test/src/lib/LeakyBucketEmbedding.t.sol` pins that, and the one state that
separates them — a capacity cut, where `levelAt` reports what is owed and
`capacity - headroomAt` reports the new capacity.

## Design notes

### Seconds, not blocks

Time is `block.timestamp`, in seconds. Block numbers appear nowhere. Block times
differ by an order of magnitude between chains and change under the same chain
over time, so a cap expressed in blocks is a different cap on every deployment
and silently becomes a different cap after a hard fork. The same `capacity` and
`leakRate` deploy unchanged anywhere.

The library takes the timestamp as a `Float` parameter rather than reading the
clock itself, so the unit is whatever the caller's numbers are in and `leakRate`
is per unit of that same clock. Everything here is seconds because the caller
hands it `block.timestamp`, which is what both of the bucket holding harnesses
in `test/concrete/` do:
`LibDecimalFloat.packLossless(int256(block.timestamp), 0)`.

### No checkpoint drift

The leak is `elapsed * leakRate` computed from the checkpoint in one multiply,
so a checkpoint in between does not change the result:

```
levelAt(settle(bucket, t1), t2) == levelAt(bucket, t2)
```

for any `t0 <= t1 <= t2`, where `bucket` is checkpointed at `t0` and
`settle(bucket, t1)` is that bucket with both of `settle`'s returns stored: a
checkpoint at `t1` with nothing filled leaves the level at `t2` that no
checkpoint leaves. `fill` checkpoints as `settle` does, so a fill at `t1` leaves
at `t2` what the same amount on top of the settled level leaves. Exactly, at
every input inside the fuzz bounds above, and it is also checked end to end
through storage: a full bucket topped up by exactly one second of leak every
second, with a write on each of those seconds, is still exactly full after half
an hour of it.

Outside those bounds it holds to the precision of the level and no further. A
`Float` subtraction keeps about 67 digits, and `rain.math.float` at `0.2.4` does
not direct its rounding, so a leak below the last digit the level holds is not
taken off as it is. `test/src/lib/FloatHazards.t.sol` pins both outcomes against
a level of `1e40`, whose last digit is `1e-27`: a leak of `1e-29` takes a whole
`1e-27` off, and a leak of `1e-37` takes nothing. A read does that once. A
checkpoint does it once per checkpoint, because the stored timestamp advances
over the time whose leak was rounded. Ten settles a second apart at `1e-29` per
second leak `1e-26` where the unsettled bucket reads `1e-27` down, which is the
permissive direction: a unit in the level's last digit of headroom per
checkpoint, from `fill` as much as from `settle`. At `1e-37` per second the same
ten leak nothing where the unsettled bucket reads `1e-27` down.

This is worth stating because the usual alternative loses far more.
Implementations that store a `window` and leak at `capacity / window` per second
take a floor division on every checkpoint, so each call discards the sub unit
remainder, and a caller touching the bucket every second is credited measurably
less leak than one touching it hourly. That makes call frequency part of the
cap. Here the rate is a parameter rather than a quotient, so the only per call
remainder is the one below the level's 67th digit.

The cost is that `leakRate` is per second, so a policy written as "X per day" is
`X / 86400` and is rounded once, off chain, where the rounding is deliberate and
visible. Round down, so the on chain rate is never faster than the policy.

### Arithmetic, and which way it fails

Every operation is a `Float` operation from
[`rain.math.float`](https://github.com/rainlanguage/rain.math.float) at `0.2.4`.
Eight distinct operations in the whole file: `add`, `sub`, `mul`, `max`, `lt`,
`gt`, `isZero` and the `packLossless` that spells zero. There is no saturating
math, no packing, no `unchecked` block, no assembly and no hand rolled overflow
guard anywhere in `src/`, because a bucket has no width to overflow.

What is left of the old saturation is the clamps at zero, and the direction of
each is a security argument rather than a style choice:

| Expression                        | Clamped | Because the alternative is                                                                                                                                                                                            |
| --------------------------------- | ------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `level - elapsed * leakRate`      | at zero | a negative level, which reads as _more_ headroom than the capacity — free headroom, and a burst above `capacity`                                                                                                      |
| `timestamp - checkpoint`          | at zero | a negative elapsed multiplied into the leak, which _raises_ the level: a bucket charged for time that never passed                                                                                                    |
| `capacity - levelNow`             | at zero | a negative headroom handed to a caller, where the bucket is over its capacity and what fits is nothing                                                                                                                |
| stored `leakRate`, in `setPolicy` | at zero | settling at a negative rate, which _raises_ the level for time that passed, or refusing, which leaves the bucket no way to take a valid policy; no leak credited is a level at or above the one any valid rate leaves |

A clock at or behind the checkpoint therefore credits **no leak**, rather than
reverting or crediting a negative one. Reverting would let a backwards clock
brick minting until it caught up. Crediting nothing can only ever report a level
at or above the true level, so it can only ever hand out _less_ headroom than
reality.

The write path has to keep what the read path refuses. A fill at a backwards
clock returns **the later of that clock and the stored checkpoint**, never the
earlier: crediting no leak for the backwards step and then recording the earlier
second leaves the same interval to be measured again on the next read, which
pays out exactly the headroom the clamp just declined. That makes the property
above hold end to end and not only on a read. `fill` hands back the level and
the second it belongs to together, and the caller stores both.

The library **reverts** rather than answering on the values that cannot mean
anything — a negative `capacity`, `leakRate`, `level` or timestamp — and it
refuses them at the parameter, by name, from `levelAt`, `headroomAt`, `settle`
`fill` and `setPolicy`; `setPolicy` also refuses the policy it is asked to
store. `fill` then refuses a zero amount and a negative amount by name. The
negative amount is the case the old type carried for free: an amount was a
`uint256` and could not be negative, where a `Float` can be, and a negative fill
drains the bucket, so it mints under a cap it never reached.

### Precision

A `Float` is a signed 224 bit coefficient and a signed 32 bit exponent in one
word, and the number it names is `coefficient * 10 ** exponent`. Two things
follow that the fixed point bucket had no way to express, and
`test/src/lib/FloatHazards.t.sol` is where the suite goes at them.

**Exact to about 67 digits, and no further.** A sum or a product needing more
digits than the coefficient holds keeps its magnitude and drops its tail, so an
amount far enough below the level's scale can round away against it. The rest of
the suite fuzzes whole numbers at exponent zero inside bounds that keep every
assertion exact — the widest product it can build is about 58 digits. What the
hazard file adds is the other side: fills across a range of exponent gaps, from
an amount at the level's own scale down to eighty orders of magnitude under it.
There a fill either lands or is refused, and the third outcome — a fill accepted
and reported successful that left the stored level exactly as it found it, a
mint nothing was charged for — is refused by the library rather than merely
tested against: `fill` compares the new level to the old and reverts with
`LeakyBucketAmountNotCredited` unless the level rose. That comparison is
numeric, not on the packed word. What it pins is that the level moved, not that
the whole amount was credited; the tail can still be dropped, which is what the
paragraph above says. The boundary is exact — against a level of `1e40` the
smallest amount still credited is `1e-27`, and `1e-28` is refused. A refusal can
also come from the arithmetic: `rain.math.float` reverts on an exponent it
cannot represent rather than quietly replacing the value with zero, so a bucket
call can revert with one of that library's errors as well as with one of the six
above.

**One number has many words.** `1800e0` and `18e2` are the same number packed
two ways, and which one an operation lands on is an artifact of the arithmetic
rather than anything the bucket promises. Everything the library does with a
`Float` goes through the numeric comparisons, `isZero` included — which is why a
zero coefficient carried at a non-zero exponent, something only a caller
decoding a `Float` off the wire can hand over, is still zero, still a zero
amount and still refused. A consumer comparing `Float.unwrap` words is comparing
spellings rather than values, and that reaches the error surface: a `Float` is a
user defined value type over `bytes32`, which is what the errors above carry in
their ABI signatures, so a caller decoding one compares those fields with `eq`
rather than as bytes.

### Storage layout

A `LeakyBucket` is four words, one `Float` each: `level`, `timestamp`,
`capacity`, `leakRate`. This library packs nothing; `Float` does its own
packing, the signed 32 bit exponent in the high bits over the signed 224 bit
coefficient in the low 224.

The level and the second it was recorded at used to share one word, and
`LEAKY_BUCKET_LEVEL_MAX` and `LEAKY_BUCKET_TIMESTAMP_MAX` were the widths of
those two fields. Both constants are gone with the packing, as is the
`LeakyBucketCapacityOverflow` refusal that enforced the first of them, and so
are the `pack` and `unpack` entry points.

A zero bucket is an empty bucket at the epoch — the zero `Float` is the number
zero, in each of the four fields — which is why an untouched slot needs no
initializer, and, on the way out, why `delete` on a bucket is a full refund of
whatever was outstanding rather than cleanup. The library cannot tell a cleared
level from one that was never written, so that is a warning rather than a guard,
and `test/src/lib/LibLeakyBucket.t.sol` asserts it as one.

Reading answers rather than reverting for any level and any clock inside the
fillable domain, fuzzed over the same bounds as everything else. The old claim
was wider: every 256 bit word was some valid bucket, so a slot holding arbitrary
bits read as one. Two of the four fields can now be meaningless, and those two
are refused by name instead of read.

## Gas

A fill reads the bucket's four fields and the caller writes two of them, the
level and the checkpoint it belongs to, which are two slots now rather than one
packed word. Both of those cost more than the packed bucket did, and so does
every number in it: a `Float` operation is a library call over a coefficient and
an exponent rather than an opcode.

`test/src/lib/LibLeakyBucketGas.t.sol` logs the current figures and asserts a
coarse band around each. Run it for the numbers. They are not reproduced here: a
gas figure does not survive a change of optimizer settings, compiler or EVM
version, so a table of them in a README is wrong as soon as any of those moves
and nothing makes it fail when it does.

## Why this exists

Nothing off the shelf was audited, openly licensed _and_ a contract agnostic
library at the same time, as at September 2026:

| Candidate                                                                                                                            | Licence                                         | Audited                                                                    | Fit                                                                                                   |
| ------------------------------------------------------------------------------------------------------------------------------------ | ----------------------------------------------- | -------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------- |
| [OpenZeppelin 5.7 `RateLimiter`](https://github.com/OpenZeppelin/openzeppelin-contracts/blob/master/contracts/utils/RateLimiter.sol) | MIT                                             | **No** — OZ's `audits/` stops at v5.6 (Feb 2026); this file is new in v5.7 | One shared `capacity`/`window` for every key, so it cannot express per minter caps of different sizes |
| [Lombard `RateLimitsV2`](https://github.com/lombard-finance/evm-smart-contracts/blob/main/contracts/libs/RateLimitsV2.sol)           | MIT header, but **no LICENSE file in the repo** | Yes (OpenZeppelin)                                                         | `uint32` timestamp **fails open** after 2106; `public`, so it needs linking                           |
| [Chainlink CCIP `RateLimiter`](https://github.com/smartcontractkit/chainlink-ccip)                                                   | **BUSL-1.1**                                    | Yes                                                                        | Licence rules it out                                                                                  |
| [Hyperlane `RateLimited`](https://github.com/hyperlane-xyz/hyperlane-monorepo/blob/main/solidity/contracts/libs/RateLimited.sol)     | MIT OR Apache-2.0                               | Partial                                                                    | An `OwnableUpgradeable` **contract** with governance built in, not a library                          |

## Licence

DecentraLicense 1.0 (`LicenseRef-DCL-1.0`). Full text in
[`LICENSES/LicenseRef-DCL-1.0.txt`](LICENSES/LicenseRef-DCL-1.0.txt), which
`LICENSE` is a symlink to. That is the same question the table above asks of
every alternative, so it is answered here for this library too.

The repo is [REUSE](https://reuse.software) compliant: every file carries an
`SPDX-License-Identifier` or is annotated in `REUSE.toml`, and `reuse lint` runs
in CI.

## Audit scope

Not yet audited. The intended scope is `src/`, which is one file, plus the one
dependency it imports by path: `LibDecimalFloat` from `rain-math-float` at
`0.2.4`. Every number in a bucket is a `Float` and every operation on one is
that library's, so a review of this library's arithmetic is a review of how it
calls that one. Nothing in this repo, and nothing in the published
`rain-math-float` package, records an audit of it — the Protofire audit of
`rain.math.saturating` that the old `LibSaturatingMath` came with went out with
the fixed point. The properties an audit should hold the implementation to are
the ones fuzzed in `test/src/lib/`:

- No burst can exceed `capacity`, at any point in a bucket history. `capacity`
  bounds the level, the headroom and any single fill at every instant, elapsed
  time never enlarges a single fill, and idling banks no credit however long it
  lasts. This is the security-critical property.
- A fill that consumes the bucket leaves zero headroom at that same second, and
  the refill afterwards is bounded by `capacity` as well.
- Leaking never raises the level, at any input.
- Exactly the reported headroom fits when it is positive, a zero headroom is
  refused as a zero fill, and any amount above it is rejected.
- Checkpointing changes nothing inside the fuzz bounds. "No checkpoint drift"
  says what it changes at a rounding boundary.
- Every clamp at zero goes the conservative way, per the table above.
- A stored checkpoint never moves backwards, so a fill at a stale clock is not
  observable at any later second.
- Reading answers everywhere inside the fillable domain, and the values outside
  it — a negative capacity, leak rate, level or timestamp — are refused by name
  at `levelAt`, `headroomAt`, `settle`, `fill` and `setPolicy`. `fill` refuses a
  zero and a negative amount by name; a leak the arithmetic cannot hold is that
  arithmetic's refusal at every entry point. Every error's selector is pinned to
  its signature.
- `headroomAt` and `fill` agree at every input either will answer, and refuse
  exactly the same buckets.
- `levelAt` reports what is owed rather than what fits, which is the one thing
  `capacity - headroomAt` cannot do after a capacity cut.
- `settle` returns the level `levelAt` reports and a checkpoint that never moves
  backwards, and refuses the buckets `fill` refuses.
- `setPolicy` refuses a negative policy before it is stored, and returns the
  bucket settled at the stored rate and carrying the new policy. A bucket whose
  policy only ever changes through it leaks, over any history of rates, what
  each rate leaked over the time it was in force, exactly inside the fuzz bounds
  and to the precision of the level outside them.
- A fill at an exponent far below the level's either lands or is refused, and
  never lands on the level word it started from, and a zero written at a
  non-zero exponent is still a zero amount.

`test/lib/` holds what the tests measure themselves against, kept apart from the
thing that ships: `LibLeakyBucketSlow` is the same leak written as a one unit of
time at a time loop, which the closed form is checked against, and
`WorkedPolicy` is the worked policy — a 3600 unit burst draining at one unit per
second — in one place, so no test restates it. `LibCheckpointWord`, which
restated the word layout as literals, went out with the layout.

## Development

`dependencies/` and `remappings.txt` are gitignored, so a fresh clone has
neither and `forge test` fails on unresolved imports before it reaches anything
about this library. Install them first:

```
nix develop
forge soldeer install
forge test
```

`forge soldeer install` reads the `[dependencies]` table in `foundry.toml`,
populates `dependencies/`, and writes `remappings.txt`. Nothing else regenerates
the remappings, so re-run it after any edit to that table.

That is the order CI runs in: the shared `rainix-sol` workflow installs soldeer
dependencies before `slither`, `forge fmt`, `forge lint` and `forge test`.

## Releasing

Published to the Soldeer registry as `rain-lib-leakybucket` by
`.github/workflows/package-release.yaml`, which calls rainix's
`rainix-autopublish` on every push to `main`. Nothing publishes from a tag, from
another branch, or from a local machine. The contract in full is the rainix
README's "Release lifecycle"; below is what a maintainer of this repo owes it.

A run publishes only if the packaged content changed against the newest
published revision, and only once every other workflow run on that same commit
has finished green.

**The version is a patch bump unless a tag says otherwise.** It is derived as

```
max(patch_bump(newest published), highest next-v<x.y.z> merged into HEAD)
```

Nothing infers semver from a diff. Adding a field to `LeakyBucket`, or changing
the parameters of `LeakyBucketCapacityExceeded`, publishes as a patch bump and
consumers on a patch range take it silently. A breaking change needs an intent
tag on its own commit, pushed _before_ that commit merges:

```
git tag next-v0.2.0 <commit>
git push origin next-v0.2.0
```

Breaking here means anything a consumer compiles against or decodes: the fields
of `LeakyBucket` and their order, which is a stored layout, any error's
signature, the name or parameters of any `internal` function, and the
`rain-math-float` revision `src/` imports by path.

There are two ways to lose an intent tag, and neither of them goes red.

- Pushing it after the merge. The gate reads `git tag --merged HEAD` in the run
  that publishes, so a tag that lands afterwards raises whatever merges next
  instead, mislabelling two versions rather than one. There is no correction
  after the fact: Soldeer revisions are immutable.
- Squash- or rebase-merging the pull request it sits on. The tagged commit never
  becomes an ancestor of `main`, so no run ever sees it. This repository allows
  squash and rebase merges today, so use a merge commit for any pull request
  carrying a `next-v` tag.

A first publish needs a `next-v` tag as its seed: with no revision on the
registry there is nothing to patch-bump and the gate will not guess. This repo's
seed was `next-v0.1.0`.

A successful publish pushes a `sol-v<x.y.z>` tag onto the published commit and
creates a GitHub release on that tag. Those two are the release record; the
publish never writes to `main`.
