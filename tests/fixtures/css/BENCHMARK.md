# CSS profiling results

Measured on an Apple M3 Pro, macOS ARM64, Nim 2.2.12, `atomicArc`, threads enabled.
The baseline is Matter main at `3c98cb245dc4d13d91c1d22b4918ad04b2e328f6`.
Both versions use the same checked-in CSS grammar and benchmark harness.
Compilation and file loading are outside the document timings; token snapshot
serialization is included. Every pass begins with fresh document state.

## Complete tokenization

Release builds, no time limit:

| Merenda theme | Baseline | Search caching | Final | Speedup |
| --- | ---: | ---: | ---: | ---: |
| synthwave83 (442 lines) | 3.7–3.9 s | 0.90 s | 0.41–0.44 s | about 9× |
| aqua (1,018 lines) | 6.98 s | 1.90 s | 0.77 s | 9.1× |
| macos (442 lines) | 1.67 s | 0.65 s | 0.32 s | 5.2× |
| peachy (402 lines) | 2.81 s | 0.83 s | 0.35 s | 8.0× |

The synthwave83 result uses three passes; the other themes use one pass each.
The three other themes came from the sibling Merenda checkout at the commit
recorded in the fixture README. All line counts include the trailing empty line.
The slowest synthwave83 lines fell from roughly 110 ms to 6 ms. Aqua's slowest
line fell from roughly 550 ms to 13 ms. Token counts are unchanged (5,534 for
synthwave83); corrected scope paths now match the reference.

A default debug build reproduced the sluggish editor behavior: synthwave83 took
42.8 s (10 lines/s), versus 9.6 s (46 lines/s) with search caching and 5.0 s
(89 lines/s) with nearby probes, before the final borrowing optimization.
Release builds are substantially faster. These are observations, not timing
assertions in the test suite.

## Hot path and changes

Sampling the baseline with `sample matter-css-baseline 3 -file /tmp/css.sample`
placed almost all tokenizer samples inside Reni regex searches. Unicode case
folding, character classes, and lookbehinds dominated. Temporary per-pattern
timers found roughly 2,378 searches each for several CSS keyword/function
expressions in one 442-line pass. Failed searches repeatedly scanned the same
remaining text at successive token positions. Recompiling anchored expressions
was a much smaller contributor.

Matter remembers each rule's next match or failure within a single scan of a
line. A successful match is reused only until the cursor passes its consumed
start (`Match.startChar`, which remains correct for `\K`). Expressions containing
`\G` are reused only for the same original cursor and anchor position. The cache
is local to the scan, so captured substrings, subsequent lines, and independent
calls cannot share stale results. It holds at most one match per visited rule.

Rule traversal also stops when the first matching rule starts at the cursor.
Pattern order still resolves ties. This shortcut is disabled for graphs using
`\K`, which can move a reported start backward inside a lookbehind. End rules
and injections still participate in their usual priority checks.

The second round probes up to eight nearby ASCII positions with anchored
matches before searching every rule over the full suffix. Most CSS punctuation,
properties, and selectors match nearby. Full searches remain the fallback for
long gaps, non-ASCII input, and `\K`; `\G` and longest-match expressions keep
their original search origin. This avoids the expensive distant selector probes
that exceeded the timed regex budget.

The Markdown profile also exposed copies of Reni's compiled regex objects when
selecting an anchor variant. Borrowing that immutable variant removed the
per-probe regex copy/destruction, confirmed by compiler ARC expansion. The later
native Reni integration removes separate anchor variants entirely; identical
source expressions still share an immutable compiled regex within the grammar.

The optimization initially preserved byte-identical token snapshots for all
four themes. Comparing against the actual VS Code reference then exposed three
pre-existing compatibility defects, now covered by regression tests:

- Space-separated `name` and `contentName` values were emitted as one scope.
- Two distinct zero-width begin rules were mistaken for an infinite loop,
  truncating CSS media queries and corrupting following HTML state.
- Retokenized captures inherited overlapping capture names, adding an unwanted
  tag scope to SVG attributes.

The final synthwave83 and HTML feature snapshots match the reference exactly.
The CSS grammar itself has not been simplified or patched.

## Time-limited calls

With `timeLimitMs = 100` and the unchanged
`MatterTimedRegexStepLimit = 10000`, synthwave83 now completes all 442 lines in
0.41 s, with **zero interrupted lines**, all 5,534 tokens, and the same reference
CRC32 `290396D3` as unlimited calls. The initial implementation interrupted 83
lines under this cap; the new nearby probes avoid the problematic full searches.

The regression test uses a generous wall-clock deadline with the same regex step
cap and checks the entire reference snapshot. Applications must still handle
`stoppedEarly` for arbitrary input and grammars.

Those CSS measurements used Reni
`7703aa83d8bbd358872bbab388b2c62e6798b88a`, verified as upstream HEAD on
2026-10-11. No dependency changes or larger step budgets were needed for that
stage. The subsequent HTML work uses the named fork branch
`elcritch/reni#feat/textmate-compat` (measured at `97b95d2`), proposed in
[upstream Reni PR #84](https://github.com/fox0430/reni/pull/84).

Three release passes with native capture/anchor options and shared end/while
patterns measured 398.9–416.9 ms for synthwave83 with `timeLimitMs = 100`.
All 5,534 tokens and CRC32 `290396D3` are unchanged, with zero interrupted
lines. CSS performance remains close to the preceding optimized result.
