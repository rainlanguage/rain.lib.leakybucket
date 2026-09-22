# Changelog

What changed for a consumer, keyed by the `sol-v<x.y.z>` tag the publish
pipeline creates. The registry version is derived from a content hash and a
patch bump, so on its own it says nothing about compatibility — this file is
where that lives.

Breaking, here, is anything a consumer compiles against or decodes: the packed
word layout or its width constants, an error's signature, the name or parameters
of an `internal` function, or the revision of `rain-math-saturating` that `src/`
imports by path. A breaking change needs a `next-v<x.y.z>` tag on its commit
before that commit merges — the rules, and the two silent ways to lose such a
tag, are in the rainix README under
[Release lifecycle](https://github.com/rainlanguage/rainix#release-lifecycle).

This file is not shipped in the Soldeer package, deliberately. The publish gate
hashes exactly what the uploaded zip would contain, so shipping it would make
every edit to it register as a content change and publish a new revision of
byte-identical source. Read it here, at the `sol-v` tag you are on.

Every merge that changes `src/` adds its entry under `## Unreleased`; a publish
moves that heading down to the `sol-v` tag the run created.

## Unreleased

Breaking, and it removes more than it keeps. The library is reduced to the
minimum that does the job it was asked for: refuse an amount that would exceed
the capacity, otherwise record it.

- `LibLeakyBucketCheckpoint.sol` is **deleted**. Its behaviour is now
  `LibLeakyBucket`, which is the whole package. A consumer changes the import
  and the call prefix; the arguments and the returned word are unchanged.
- The exported surface is `fill`, `headroomAt`, `LEAKY_BUCKET_LEVEL_MAX`, and
  the three errors `fill` can raise. Everything else is `private`: `leak`,
  `levelAt`, `headroomFrom`, `fillAt`, `pack`, `unpack`, `checkCapacity`,
  `checkTimestamp`, `checkFillableDomain`, and the two width constants
  `LEAKY_BUCKET_TIMESTAMP_BITS` and `LEAKY_BUCKET_TIMESTAMP_MAX`.
- **Removed:** `leakRatePer` and `LEAKY_BUCKET_SECONDS_PER_HOUR` / `_DAY` /
  `_WEEK`. Per second rates are a stated requirement, so a helper that accepts a
  rate expressed per something else re-opens a decided question, and it does it
  with a floor division inside a security library. Write `100e18 / 1 days` in
  your own constructor, in your own units.
- **Removed:** `fillableAt`, at both layers. It forecasts; it does not rate
  limit.
- **Removed:** the packed `levelAt`. `headroomAt(word, t, LEAKY_BUCKET_LEVEL_MAX,
  rate)` is `LEAKY_BUCKET_LEVEL_MAX - level` exactly, so anyone holding the word
  already has it.
- **Kept:** `headroomAt`. `fill` reverts naming a capacity, not a bucket; two
  buckets can share a capacity; and an `internal` revert cannot be caught and
  relabelled in the frame that raised it. A caller metering one amount through
  several buckets provably cannot say which one refused it without this, so it
  stays, with that reason in its NatSpec.

## sol-v0.1.0

First release.

- `LibLeakyBucket` — the pure `(level, checkpoint)` core, taking the bucket
  state as arguments: `leak`, `levelAt`, `headroomAt`, `fillAt`, `fillableAt`.
- `LibLeakyBucketCheckpoint` — the same behaviour over one packed word, level in
  the high 192 bits and timestamp in the low 64, so a bucket is one storage slot
  and a fill is one `SLOAD` and one `SSTORE`: `checkCapacity`, `pack`, `unpack`,
  `levelAt`, `headroomAt`, `fillableAt`, `fill`.
- Width constants: `LEAKY_BUCKET_TIMESTAMP_BITS`, `LEAKY_BUCKET_TIMESTAMP_MAX`,
  `LEAKY_BUCKET_LEVEL_MAX`.
- Errors: `LeakyBucketCapacityExceeded(uint256,uint256,uint256)`,
  `LeakyBucketCapacityOverflow(uint256)`, `LeakyBucketLevelOverflow(uint256)`,
  `LeakyBucketTimestampOverflow(uint256)`.
- Depends on `rain-math-saturating-0.1.10`, imported by that literal path, so a
  consumer installs that exact revision.
