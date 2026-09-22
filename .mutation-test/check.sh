#!/usr/bin/env bash
# Suite command for mutation-probe, which reads the mutant set from
# `mutants.toml` at the repo root and runs this script once per mutant. Both
# files are tracked so the coverage claim in `audit/mutation-test-scans.json`
# can be re-derived by anyone, rather than only on the machine that made it.
#
# Fixed fuzz seed so a verdict is reproducible: an unseeded fuzzer makes
# SURVIVED/KILLED flaky across runs. Solidity has no separate
# artifact-generation step; `forge test` compiles the mutated source itself, so
# there is no stale artifact to regenerate.
set -uo pipefail
export FOUNDRY_DISABLE_NIGHTLY_WARNING=1
# `forge` comes from the flake devShell; run this under `nix develop -c`.
exec forge test --fuzz-seed 0xa11ce10ea11ce10e
