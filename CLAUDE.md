# rain.lib.leakybucket

Two `internal pure` libraries over 256-bit words. `capacity` is the security
number: the most a compromised minter can take in one go.

## Saturation direction is a security argument, not a style choice

The clamps in `src/` are load-bearing, and the safe direction differs per
expression — a bigger leak is a lower level is more headroom, so "saturate up"
is conservative in one place and permissive in another. Derive the direction for
the expression in front of you rather than applying a rule of thumb. Reordering
operands, or swapping a `LibSaturatingMath` call for plain arithmetic because it
reads better, can leave every test's shape intact and still hand out headroom
nobody earned. Do not hand-roll an overflow guard.

## `.soldeerignore` is an allowlist and nothing checks it

It denies `/*` and re-includes a short list of paths. A file that consumers are
meant to receive is silently missing from the published package unless it is
re-included there. No test, lint or CI job catches the omission; the package
just ships without it.

## Gas bands are an assertion, not a budget

`test/src/lib/LibLeakyBucketGas.t.sol` asserts narrow gas bands, and README.md
prints the same figures. A change that moves gas updates both numbers and says
why. Widening a band so the test goes green destroys the only signal that file
exists to give.

## `audit/mutation-test-scans.json` is evidence, appended by hand

It records mutation-scan results against a named commit, and is read by external
auditors and by org tooling as proof of test strength. A change to `src/` or
`test/` invalidates the newest entry: re-run the scan and APPEND a record. Never
edit an existing entry to match new code — that rewrites the history the record
exists to preserve.
