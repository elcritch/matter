# HTML profiling results

Measured on an Apple M3 Pro, macOS ARM64, Nim 2.2.12, `atomicArc`, threads
enabled, with a release build. Matter uses Reni's named fork branch
`feat/textmate-compat`, measured at `97b95d2`; the dependency is pinned to the
branch name. Native additions are proposed in
[upstream Reni PR #84](https://github.com/fox0430/reni/pull/84).

Each pass reuses a compiled grammar and starts with fresh document state.
Package loading and compilation are outside document timings; JSON token
serialization is included. Line counts include the trailing empty line.

| Input | Lines | Tokens | Complete document | Slowest line | Reference CRC32 |
| --- | ---: | ---: | ---: | ---: | --- |
| Merenda HTML demo | 65 | 819 | 6.38–6.68 ms | about 1 ms | `CAC2C77A` |
| HTML coverage | 81 | 1,394 | 20.29–20.62 ms | 2.3 ms | `E4417669` |

The Merenda result uses three passes; coverage uses seven. Both complete with
zero interrupted lines using a positive budget and the unchanged 10,000-step
regex cap. Loading the HTML package and compiling the grammar takes about
46–48 ms. Both HTML roots match their full reference snapshots, with unlimited
calls and with the cap enabled.

## Profile and comparison

Native sampling of the preceding Matter commit `fed6037` placed about 24% of
tokenization samples inside repeated regex compilation. Opening HTML attributes,
tags, and embedded-language regions rebuilt end expressions. Continuation
expressions could also compile again on each line.

Matter now compiles and shares end/while expressions that do not depend on begin
captures. Dynamic expressions remain resolved per opening match. Native Reni
capture and anchor options also replace the private capture-name rewrite and
four compiled anchor variants. Matching borrows the immutable compiled regex.
The optimized sample places less than 1% of tokenization samples in regex
compilation; remaining time is mostly rule traversal and matching.

For a direct comparison, remove the four newly added malformed inline-handler
lines from `coverage.html`. Both versions produce the same complete snapshot as
the reference on this 77-line input. Seven sequential passes measured:

| Version | Document range | Median |
| --- | ---: | ---: |
| Matter `fed6037` | 24.98–26.17 ms | 25.48 ms |
| Shared end/while patterns and native Reni options | 18.38–19.12 ms | 18.80 ms |

This is approximately 26% less document time. The full 81-line coverage result
above includes additional correctness cases and is not the comparison input.
Recreate the comparable input with:

```sh
python3 - <<'PY'
from pathlib import Path
source = Path('tests/fixtures/html/coverage.html').read_text()
Path('/tmp/html-comparable.html').write_text(''.join(
    line for line in source.splitlines(keepends=True)
    if 'After malformed JS' not in line
))
PY
/tmp/bench_html 7 0 /tmp/html-comparable.jsonl /tmp/html-comparable.html
```

The cache belongs to the compiled grammar graph and contains immutable regex
references. Saved states retain their resolved expressions; matching scratch
space remains thread-local. No shared mutable runtime cache was added.

## Correctness findings

Capture retokenization now sees the original input prefix ending at the capture
boundary. This preserves lookbehind offsets while preventing embedded JavaScript
from reading following HTML attributes. An unterminated quote inside `onclick`
therefore receives the reference's invalid-newline class and does not consume
the next `id` attribute.

Reference comparisons also protect tags, attributes, entities, SVG, MathML,
embedded CSS/JavaScript, punctuation, theme styles, language IDs, and saved-state
behavior. The separate host-boundary fixture records the upstream grammar's
unterminated-script recovery limitation; see the [scope guide](README.md).

The [engine comparison](../../../tools/BENCHMARK.md) measures main, this branch,
and VS Code TextMate on identical HTML, CSS, and Markdown inputs, excluding JSON
serialization. It also records correctness differences in main's output.
