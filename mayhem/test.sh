#!/usr/bin/env bash
#
# mayhem/test.sh — RUN the risingwave_sqlparser functional test suite (pre-built by build.sh).
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${SRC:=/mayhem}"
: "${MAYHEM_JOBS:=$(nproc)}"
cd "$SRC"

emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

# Same detached, vendored copy build.sh compiled from (see build.sh: VENDOR_SQLPARSER) — running
# -p risingwave_sqlparser from the full $SRC workspace instead would drag in the whole workspace
# Cargo.lock, including risingwave_source's now-unreachable pinned git commit of
# risingwavelabs/avro, unrelated to sqlparser itself.
VENDOR_SQLPARSER=/tmp/sqlparser-vendor
[ -d "$VENDOR_SQLPARSER" ] || { cp -r "$SRC/src/sqlparser" "$VENDOR_SQLPARSER" && python3 - "$VENDOR_SQLPARSER/Cargo.toml" <<'PYEOF'
import re, sys
p = sys.argv[1]
s = open(p).read()
s = re.sub(r"\n\[target\.'cfg\(not\(madsim\)\)'\.dependencies\]\nworkspace-hack[^\n]*\n", "\n", s)
open(p, "w").write(s)
PYEOF
cp "$SRC/mayhem/sqlparser-test.Cargo.lock" "$VENDOR_SQLPARSER/Cargo.lock"
}

LOG="$(mktemp)"
( cd "$VENDOR_SQLPARSER" && env -u RUSTFLAGS CARGO_TARGET_DIR="$SRC/mayhem/test-target" \
  RUSTFLAGS="--cap-lints=warn --cfg madsim" cargo "+${RUST_CHANNEL:-nightly-2026-06-11}" test ) 2>&1 | tee "$LOG"
run_rc=${PIPESTATUS[0]}

passed=$(grep -hoE '[0-9]+ passed' "$LOG"  | awk '{s+=$1} END{print s+0}')
failed=$(grep -hoE '[0-9]+ failed' "$LOG"  | awk '{s+=$1} END{print s+0}')
skipped=$(grep -hoE '[0-9]+ ignored' "$LOG" | awk '{s+=$1} END{print s+0}')
rm -f "$LOG"

if [ "$run_rc" -ne 0 ] && [ "$failed" -eq 0 ] && [ "$passed" -eq 0 ]; then
  failed=1
fi

emit_ctrf "cargo-test" "$passed" "$failed" "$skipped"
