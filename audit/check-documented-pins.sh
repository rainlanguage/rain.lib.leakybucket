#!/usr/bin/env bash
# Fails when README.md does not tell a consumer to install a dependency that
# `src/` imports, at the exact version the import hard-codes.
#
# `.soldeerignore` is an allowlist that ships `src/`, the README and the
# licences — no `foundry.toml` and no lock file — so the published package
# declares no dependencies at all. Soldeer does not make up the difference: a
# registry dependency's own dependencies are not resolved, and `--recursive-deps`
# does not change that (verified against the published 0.1.0 — the package
# installs cleanly, then `forge build` fails on the unresolved
# `rain-math-saturating-0.1.10/src/lib/LibSaturatingMath.sol`).
#
# So the README's install block is the ONLY thing standing between a consumer
# and a package that will not compile, and it is hand-written prose about a
# version number. Nothing else in CI reads it. This does.
#
# Fixing a failure means correcting the README, never relaxing the check: the
# version in the import path is the ground truth, because that literal path is
# what has to resolve on the consumer's machine.
#
# Run from the repo root.
set -euo pipefail

status=0

# A soldeer remapping is keyed on the installed directory name, which is
# `<name>-<version>`, so an import that resolves through one carries the
# dependency's exact version in its path. Relative imports carry no version and
# are excluded by the semver in the pattern. `|| true` so that finding nothing
# reaches the check below rather than tripping `set -e` with no diagnostic.
deps=$(grep -rhoE 'from "[A-Za-z0-9_.-]+-[0-9]+\.[0-9]+\.[0-9]+/' src --include='*.sol' \
       | sed -E 's/^from "//; s#/$##' | sort -u || true)

# An empty set asserts nothing while reporting success, which is exactly the
# silent-pass this check exists to prevent. `src/` has imported a versioned
# dependency since the first commit, so an empty set means the pattern no longer
# matches how imports are written, not that the dependency went away.
if [ -z "$deps" ]; then
  echo "ERROR: no version-qualified imports found in src/." >&2
  echo "This check asserts nothing on an empty set, so it fails instead of" >&2
  echo "passing silently. Update the pattern to match how src/ imports now." >&2
  exit 1
fi

for dep in $deps; do
  name=$(printf '%s' "$dep" | sed -E 's/-[0-9]+\.[0-9]+\.[0-9]+$//')
  version=${dep##*-}
  if grep -qF "forge soldeer install $name~$version" README.md; then
    echo "documented-pins: ok — README installs $name at $version"
  else
    echo "ERROR: src/ imports $dep, but README.md does not contain" >&2
    echo "  forge soldeer install $name~$version" >&2
    echo "A consumer following the README would install the wrong revision (or" >&2
    echo "none), and soldeer would remap it under a prefix the import does not" >&2
    echo "name, so the package would not compile for them." >&2
    status=1
  fi
done

exit "$status"
