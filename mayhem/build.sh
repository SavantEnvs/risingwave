#!/usr/bin/env bash
#
# mayhem/build.sh — build risingwave_sqlparser cargo-fuzz target(s) as sanitized libFuzzer
# binaries, AND build the sqlparser crate's clean test binaries for mayhem/test.sh.
set -euo pipefail

[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SRC:=/mayhem}"
# ASan fuzz + workspace test compile is RAM-heavy; default low parallelism (override via MAYHEM_JOBS).
: "${MAYHEM_JOBS:=2}"
export CARGO_BUILD_JOBS="$MAYHEM_JOBS"

cd "$SRC"

: "${RUST_DEBUG_FLAGS:=-C debuginfo=2 -C force-frame-pointers=yes}"
DWARF_FLAGS="-Zdwarf-version=3"
FUZZ_RUSTFLAGS="${RUSTFLAGS:-} --cfg fuzzing --cfg madsim -Zsanitizer=address ${RUST_DEBUG_FLAGS} ${DWARF_FLAGS}"
echo "SANITIZER_FLAGS (base, informational) = ${SANITIZER_FLAGS:-<unset>}"

FUZZ_DIR="mayhem/fuzz"
TRIPLE="x86_64-unknown-linux-gnu"

export CFLAGS="${CFLAGS:-} -gdwarf-3"
export CXXFLAGS="${CXXFLAGS:-} -gdwarf-3"

ASAN_A="$(rustc "+${RUST_CHANNEL}" --print sysroot)/lib/rustlib/${TRIPLE}/lib/librustc-nightly_rt.asan.a"
if [ -f "$ASAN_A" ]; then
  echo "stripping debug info from prebuilt ASan runtime: $ASAN_A"
  objcopy --strip-debug "$ASAN_A" 2>/dev/null || objcopy --remove-section '.debug_*' "$ASAN_A" 2>/dev/null || true
fi

FUZZ_TARGETS=()
for f in "$FUZZ_DIR"/fuzz_targets/*.rs; do
  FUZZ_TARGETS+=("$(basename "${f%.*}")")
done
[ "${#FUZZ_TARGETS[@]}" -gt 0 ] || { echo "ERROR: no fuzz targets under $FUZZ_DIR/fuzz_targets/" >&2; exit 1; }

# risingwave_sqlparser has no rust-toolchain/[workspace] of its own, so Cargo discovers it as a
# member of the OUTER monorepo workspace (walking up from src/sqlparser to /mayhem/Cargo.toml) even
# though mayhem/fuzz/Cargo.toml declares itself a standalone [workspace] — and merges that outer
# workspace's [patch.crates-io] (the madsim-rs forks of tokio-postgres et al.) into OUR resolution,
# pulling a huge unrelated, UNPINNED dependency graph (icu4x/idna) neither sqlparser nor the fuzz
# harness needs. Vendor a copy of sqlparser outside the workspace tree (no ancestor Cargo.toml to
# find) so the fuzz crate's path dependency resolves in true isolation.
VENDOR_SQLPARSER=/tmp/sqlparser-vendor
rm -rf "$VENDOR_SQLPARSER"
cp -r "$SRC/src/sqlparser" "$VENDOR_SQLPARSER"
sed -i "s#path = \"../../src/sqlparser\"#path = \"$VENDOR_SQLPARSER\"#" "$FUZZ_DIR/Cargo.toml"
# mayhem/fuzz/Cargo.lock is COMMITTED (pinned, §6.2 item 9 / §6.5): without it, an unpinned detached
# workspace re-resolves crates.io on every build, which needs the network and breaks the air-gapped
# re-run — the committed lock plus this image's already-populated cargo registry cache let a
# `--network none` re-run succeed.
[ -f "$FUZZ_DIR/Cargo.lock" ] || { echo "ERROR: $FUZZ_DIR/Cargo.lock missing — commit a pinned lockfile (air-gap contract)" >&2; exit 1; }
# Cargo resolves [target.'cfg(...)'.dependencies] into Cargo.lock for EVERY declared cfg
# combination regardless of the cfg flags this build actually passes (cfg only gates what gets
# COMPILED, not what gets RESOLVED) — so the cfg(not(madsim)) guard on workspace-hack does not
# stop cargo from pulling that monorepo-wide dependency-aggregator crate and its entire (unpinned,
# edition-2024-only) transitive graph. workspace-hack has no effect on sqlparser's actual code; drop
# it from the vendored copy instead of trying to cfg it away.
python3 - "$VENDOR_SQLPARSER/Cargo.toml" <<'PYEOF'
import re, sys
p = sys.argv[1]
s = open(p).read()
s = re.sub(r"\n\[target\.'cfg\(not\(madsim\)\)'\.dependencies\]\nworkspace-hack[^\n]*\n", "\n", s)
open(p, "w").write(s)
PYEOF
# Same air-gap contract as $FUZZ_DIR/Cargo.lock above, for the vendored copy's own (separate,
# smaller) dependency graph used by the `cargo test` step below.
cp "$SRC/mayhem/sqlparser-test.Cargo.lock" "$VENDOR_SQLPARSER/Cargo.lock"

echo "=== cargo fuzz build (ASan via RUSTFLAGS, DWARF 3) ==="
echo "RUSTFLAGS=$FUZZ_RUSTFLAGS"
echo "targets: ${FUZZ_TARGETS[*]}"

for t in "${FUZZ_TARGETS[@]}"; do
  echo "--- building fuzz target: $t ---"
  # The checkout's OWN root ./rust-toolchain (nightly-2022-10-16, pre-dating upstream's later move
  # to ci/rust-toolchain) silently overrides rustup's default toolchain for any cargo invocation
  # under $SRC, downgrading cargo-fuzz to an ancient cargo that can't parse modern crates.io
  # manifests (edition 2024) resolved fresh for the detached mayhem/fuzz workspace. Pin explicitly.
  RUSTFLAGS="$FUZZ_RUSTFLAGS" cargo "+${RUST_CHANNEL}" fuzz build --fuzz-dir "$FUZZ_DIR" -O --debug-assertions "$t"
  bin="$SRC/$FUZZ_DIR/target/$TRIPLE/release/$t"
  [ -x "$bin" ] || { echo "ERROR: expected fuzz binary not found at $bin" >&2; exit 1; }
  cp "$bin" "/mayhem/$t"
  echo "built /mayhem/$t"
done

echo "=== cargo test --no-run (vendored risingwave_sqlparser, for test.sh) ==="
# Building -p risingwave_sqlparser from the full $SRC workspace drags in the WHOLE workspace
# Cargo.lock, including risingwave_source's git dependency on a historical commit of
# risingwavelabs/avro that the remote has since rewritten past (unreachable: "object not found") —
# unrelated to sqlparser, but the workspace-wide lock makes it fatal. Test the same detached,
# vendored copy used for the fuzz build instead (see VENDOR_SQLPARSER above).
TEST_RUSTFLAGS="--cap-lints=warn --cfg madsim"
( cd "$VENDOR_SQLPARSER" && env -u RUSTFLAGS CARGO_TARGET_DIR="$SRC/mayhem/test-target" \
  RUSTFLAGS="$TEST_RUSTFLAGS" cargo "+${RUST_CHANNEL}" test --no-run )
echo "test binaries built"

echo "build.sh complete"
