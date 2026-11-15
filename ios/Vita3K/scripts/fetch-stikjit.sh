#!/usr/bin/env bash
# Fetch StikJIT (StikDebug's JIT engine as a library, MPL-2.0; it bundles jkcoxson's idevice, MIT) at a
# fixed commit into ios/Vita3K/Vendor/stikjit. It is compiled into the FlowyrRamHelper extension for the
# built-in JIT (see vita3k/ios/ramhelper/builtin_jit.mm). Does nothing if the checkout is already there.
set -euo pipefail

COMMIT="a9ccad90c7a8cb547f77ff338890e6633a65ac43"
APP="$(cd "$(dirname "${0}")/.." && pwd)"
DIR="$APP/Vendor/stikjit"

if [ -f "$DIR/Sources/StikJIT.swift" ] && [ -f "$DIR/idevice/libidevice_ffi.a" ]; then
  echo "StikJIT already fetched in $DIR"
  exit 0
fi

rm -rf "$DIR"
mkdir -p "$DIR"
(
  cd "$DIR"
  git init --quiet
  git fetch --quiet --depth 1 https://github.com/StikDebug/StikJIT.git "$COMMIT"
  git checkout --quiet FETCH_HEAD
)
[ -f "$DIR/Sources/StikJIT.swift" ] || { echo "StikJIT fetch failed" >&2; exit 1; }
echo "Fetched StikJIT $COMMIT into $DIR"
