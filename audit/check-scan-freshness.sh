#!/usr/bin/env bash
# Fails when `audit/mutation-test-scans.json` describes a tree that no longer
# exists. That record is the artifact an external auditor is handed as evidence
# of test strength, and it is appended BY HAND: nothing in it is derived from
# the working tree, so without this check it goes stale silently and always in
# the direction of overstating coverage.
#
# Two things are checked, in order:
#
#   1. The generator is present. `mutants.toml` defines the mutants the record
#      counts and `.mutation-test/check.sh` is the suite command with the fixed
#      fuzz seed the verdicts depend on. A record whose generator is absent is
#      a claim nobody else can re-derive, which is how this check came to exist
#      (issue #35: both files were hidden in one clone's `.git/info/exclude`).
#
#   2. The newest record still describes HEAD. `src/` is what the mutants
#      target and `test/` is the suite that kills them, so a change to EITHER
#      can turn a killed mutant into a survivor while the record keeps saying
#      it was killed. Both are compared.
#
# Fixing a failure means re-running the scan and APPENDING a record, never
# editing an existing one.
#
# Complements, and does not duplicate, rainix's `mutation-ledger` action, which
# checks the record's shape and that each recorded SHA is an ancestor of HEAD
# but never compares the described tree to the actual one. This check belongs
# upstream alongside it; it lives here until it can be lifted there.
#
# Run from the repo root. Needs full history (`fetch-depth: 0` in CI).
set -euo pipefail

record="audit/mutation-test-scans.json"

# No record is not a defect: this validates a claim, it never requires one.
if [ ! -f "$record" ]; then
  echo "mutation-scan-freshness: no $record; skip"
  exit 0
fi

missing=0
for generator in mutants.toml .mutation-test/check.sh; do
  if [ ! -f "$generator" ]; then
    echo "ERROR: $record makes a coverage claim but $generator is not in the repository." >&2
    missing=1
  fi
done
if [ "$missing" -ne 0 ]; then
  echo "The record counts mutants that nothing here defines, so no reviewer or" >&2
  echo "auditor can re-derive it. Track the generator with the claim." >&2
  exit 1
fi

# The claim in force is the newest run. Ordered by timestamp string, which is
# the ordering rainix's mutation-ledger and roh-scan both use, rather than by
# position in the array.
newest=$(jq -r 'max_by(.timestamp) | .commit' "$record")
if [ -z "$newest" ] || [ "$newest" = "null" ]; then
  echo "ERROR: could not read a commit from $record." >&2
  exit 1
fi

if ! git cat-file -e "${newest}^{commit}" 2>/dev/null; then
  echo "ERROR: $record names commit $newest, which is not in this history." >&2
  echo "Either the history was rewritten or the SHA is wrong; the run it" >&2
  echo "records is unfalsifiable until that is resolved." >&2
  exit 1
fi

if ! git diff --quiet "$newest" HEAD -- src test; then
  echo "ERROR: src/ or test/ has changed since the newest mutation scan ($newest)." >&2
  echo "$record still reports that scan's kill count, so it now overstates" >&2
  echo "coverage of the current tree. Re-run the scan and APPEND a record." >&2
  git diff --stat "$newest" HEAD -- src test >&2
  exit 1
fi

echo "mutation-scan-freshness: clean — src/ and test/ unchanged since $newest"
