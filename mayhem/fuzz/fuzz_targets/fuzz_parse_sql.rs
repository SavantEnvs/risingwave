#![no_main]
use arbitrary::{Arbitrary, Unstructured};
use libfuzzer_sys::fuzz_target;
use risingwave_sqlparser::parser::Parser;

// Port of the upstream honggfuzz harness (src/sqlparser/fuzz/fuzz_targets/fuzz_parse_sql.rs)
// as a libFuzzer target for Mayhem. honggfuzz-rs's `fuzz!(|data: String| ...)` derives the
// String via `Arbitrary::arbitrary` (honggfuzz-rs src/lib.rs `fuzz!` macro), which reads a
// length prefix from the tail of the buffer and takes the longest valid UTF-8 prefix of the
// rest — not a strict whole-buffer UTF-8 decode. Most of the saved mayhemheroes crashers are
// not valid UTF-8 as a whole file, so `str::from_utf8(data)` skips them outright; use the same
// Arbitrary derivation honggfuzz used so the saved crashers replay.
fuzz_target!(|data: &[u8]| {
    let mut u = Unstructured::new(data);
    if let Ok(s) = String::arbitrary(&mut u) {
        let _ = Parser::parse_sql(&s);
    }
});
