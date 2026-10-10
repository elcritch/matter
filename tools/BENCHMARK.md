# Comparing Matter and VS Code TextMate

`bench_compare.nim` and `bench_textmate.cjs` measure the same public
`tokenizeLine` operation over whole documents. They reuse compiled grammars,
start each document with fresh state, and run without a time limit. Timings
exclude file loading, grammar loading, output normalization, and JSON
serialization. A separate untimed pass saves complete visible UTF-8 token
snapshots for correctness comparisons. The extra `tokenizeAndSnapshotMs` field
measures one diagnostic pass including normalization/serialization; it is not
part of the engine timing samples.

Use the same prepared grammar directory for both Matter revisions and TextMate.
Preparation removes Matter's runtime fence extension, leaving the same upstream
static/fallback rules available in every engine. The CSS benchmark overrides
`source.css` with the existing Kosmo fixture; HTML and Markdown use bundled CSS.
All embedded grammars are registered explicitly, including on main, so missing
package dependencies cannot make main appear faster by doing less work.

## Reproduction

First install `vscode-textmate@9.2.0` and `vscode-oniguruma@2.0.1`, and extract
the bundled grammar archives, following the
[reference setup](../tests/fixtures/markdown/README.md#benchmark-and-reference-reproduction).
Then prepare identical JSON grammars and build the branch harness:

```sh
export NODE_PATH=/tmp/matter-tm-reference/node_modules
node tools/bench_textmate.cjs --prepare \
  /tmp/matter-reference-grammars /tmp/matter-comparison-grammars
nim c -d:release --path:src -o:/tmp/bench_compare_branch tools/bench_compare.nim
```

Build the same harness against main's source and main's Atlas-resolved
dependencies in a detached worktree. Do not build main against the Reni fork.
For example, after `atlas install` in that worktree:

```sh
git worktree add --detach /tmp/matter-main-compare main
cp tools/bench_compare.nim /tmp/matter-main-compare/bench_compare.nim
cd /tmp/matter-main-compare
atlas install
nim c -d:release --path:src -o:/tmp/bench_compare_main bench_compare.nim
```

Run commands from the branch checkout so fixture paths are identical. Arguments
are grammar directory, scope, input, warmup documents, measured documents,
snapshot path, and optional overriding grammar. For CSS:

```sh
/tmp/bench_compare_main /tmp/matter-comparison-grammars source.css \
  tests/fixtures/css/synthwave83.css 3 9 /tmp/css-main.jsonl \
  tests/fixtures/css/css.tmLanguage.json
/tmp/bench_compare_branch /tmp/matter-comparison-grammars source.css \
  tests/fixtures/css/synthwave83.css 3 9 /tmp/css-branch.jsonl \
  tests/fixtures/css/css.tmLanguage.json
node tools/bench_textmate.cjs /tmp/matter-comparison-grammars source.css \
  tests/fixtures/css/synthwave83.css 20 9 /tmp/css-textmate.jsonl \
  tests/fixtures/css/css.tmLanguage.json
cmp /tmp/css-branch.jsonl /tmp/css-textmate.jsonl
```

Repeat without the override argument for HTML (`text.html.derivative`,
`tests/fixtures/html/merenda.html` or `coverage.html`) and Markdown
(`text.html.markdown`, `tests/fixtures/markdown/merenda.md`). Three warmup
documents suffice for native Matter; twenty allow the JavaScript runtime and
Oniguruma scanners to warm up. Execute engines sequentially, avoiding concurrent
builds or benchmarks.

## Results and interpretation

Measurements use release Matter with Nim 2.2.12, `atomicArc`, and threads enabled
on an Apple M3 Pro/macOS ARM64. Main is `3c98cb2` with upstream Reni `7703aa8`;
the branch uses the named Reni fork dependency, measured at `97b95d2`.
The standalone reference uses Node v26.10.0 ARM64, TextMate 9.2.0, and Oniguruma
2.0.1's WebAssembly build. This measures the tokenizer libraries, not the VS Code
UI or an HTML/CSS/Markdown document parser.

Each result is the median of nine warmed whole-document samples. Main's speed
must be read alongside its scope correctness; incomplete highlighting is a
different amount of work. Full ranges and output checks accompany the recorded
comparison below.

| Fixture | Lines | Main | Branch | VS Code TextMate |
| --- | ---: | ---: | ---: | ---: |
| Merenda synthwave83 CSS | 442 | 3,760 ms* | 404.8 ms | 38.28 ms |
| Merenda HTML demo | 65 | 7.95 ms | 5.73 ms | 1.59 ms |
| HTML coverage | 81 | 25.86 ms* | 18.53 ms | 24.45 ms |
| Merenda Markdown | 576 | 100.98 ms* | 142.87 ms | 7.52 ms |

`*` Main's output differs from the reference. The branch's complete visible
token ranges and scope paths match TextMate byte-for-byte on every fixture.

| Fixture | Main tokens | Branch / reference tokens | Main lines with different output |
| --- | ---: | ---: | ---: |
| CSS | 5,534 | 5,534 | 109 of 442 |
| HTML demo | 819 | 819 | 0 of 65 |
| HTML coverage | 573 | 1,394 | 67 of 81 |
| Markdown | 634 | 1,745 | 407 of 576 |

The branch is 9.29× faster for CSS, with corrected scopes, and 1.39× faster for
the reference-compatible HTML demo. HTML coverage also takes less time while
restoring missing scopes. Main's apparently faster Markdown result omits most
of the highlighting work; it is not a correctness-preserving speed baseline.
The preceding corrected branch implementation measured about 193 ms including
JSON, versus about 141 ms after the native Reni/shared-end-pattern work; see the
[Markdown profile](../tests/fixtures/markdown/BENCHMARK.md).

Compared with TextMate, the branch takes 10.6× as long on CSS, 3.6× on the HTML
demo, and 19.0× on Markdown. The branch is 1.32× faster on the HTML coverage
fixture. There is no single engine speed ratio: the grammar and input determine
the workload. Matter's profiles still place most time in rule traversal and
individual regex searches; these results make that the next area to investigate.

Ranges across the nine engine-only samples were:

| Fixture | Main | Branch | TextMate |
| --- | ---: | ---: | ---: |
| CSS | 3,719.7–3,881.4 ms | 399.8–416.1 ms | 38.05–38.41 ms |
| HTML demo | 7.90–8.14 ms | 5.69–5.76 ms | 1.54–1.73 ms |
| HTML coverage | 25.64–26.54 ms | 18.16–19.98 ms | 23.57–27.13 ms |
| Markdown | 100.45–101.33 ms | 141.88–146.99 ms | 7.41–7.63 ms |

[Raw samples, source hashes, token counts, and checksums](benchmarks/engines-m3pro.json)
are retained with this report. Engine-only timings differ from the older fixture
tools' measurements because those include JSON serialization.
