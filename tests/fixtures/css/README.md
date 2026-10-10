# CSS performance fixtures

These files make CSS tests and benchmarks independent of a sibling checkout or
an installed editor. Run the benchmark from the Matter repository:

```sh
nim c -d:release --path:src -o:/tmp/bench_css tools/bench_css.nim
/tmp/bench_css 3
```

Arguments are the number of document passes, the per-line time limit in
milliseconds (`0` disables it), an optional output path for a token snapshot, and
an optional CSS input path. Pass an empty snapshot path to skip writing it:

```sh
/tmp/bench_css 3 0 "" ../merenda/src/merenda/nimkit/themes/stylesheets/aqua.css
```

Every pass starts with fresh document state and reuses the compiled grammar.
An interrupted line resets the next line's state, matching Merenda's caller.

- `synthwave83.css` is copied unchanged from Merenda's
  `src/merenda/nimkit/themes/stylesheets/synthwave83.css` at commit
  `52718eb60f56279cf2f0c1d3f13d34decead63a2`. It exercises custom properties,
  percentages, scientific notation, gradients, shadows, selectors, and `var()`.
  Its SHA-256 is
  `a7c6b0355b8066d3b6040c939227b7420e5f2894424396b943c3518983bccb64`.
  See `MERENDA-LICENSE.txt` (BSD 3-Clause).
- `css.tmLanguage.json` is the Microsoft CSS grammar copied unchanged from
  Kosmo's installed `css:css` package. Kosmo records the VS Code source commit
  `0cc5212573a6f95ad49962c7032cb769c85cfe85`; the grammar itself records
  [vscode-css commit de9e6beee756760f31b15efbd782735fc25de3db](https://github.com/microsoft/vscode-css/commit/de9e6beee756760f31b15efbd782735fc25de3db).
  Its SHA-256 is
  `55a3e184f702da6a5a64dc4d7ce82ab298a1bae8d35e2924483941eb223d54b1`.
  See `MICROSOFT-LICENSE.txt` (MIT, retained from the bundled VS Code package).

There are 441 newline-terminated source lines; the benchmark also tokenizes the
empty line after the final newline, as returned by Nim's `splitLines`.

## Reference compatibility

`tcssgrammar.nim` checks every visible range and scope against a CRC32 snapshot
generated with VS Code's reference engine. `thtmlgrammar.nim` does the same for
`../html/features.html`, using the bundled HTML/JavaScript grammars plus this CSS
grammar. The HTML fixture covers embedded languages, media queries, attributes,
entities, comments, SVG, MathML, CDATA, custom elements, and non-ASCII text.

The tests run entirely in Nim, offline. To regenerate a reference snapshot:

```sh
npm install --prefix /tmp/matter-tm-reference --ignore-scripts --no-audit --no-fund \
  vscode-textmate@9.2.0 vscode-oniguruma@2.0.1
NODE_PATH=/tmp/matter-tm-reference/node_modules node tools/reference_tokens.cjs \
  tests/fixtures/css source.css tests/fixtures/css/synthwave83.css /tmp/css-reference.jsonl
/tmp/bench_css 1 0 /tmp/css-matter.jsonl
cmp /tmp/css-reference.jsonl /tmp/css-matter.jsonl
```

For the HTML snapshot, give the reference tool a directory containing this CSS
grammar and the `.tmLanguage`/`.tmLanguage.json` files extracted from
`data/grammars/vscode-html-1.95.3.zip` and
`data/grammars/vscode-javascript-1.95.3.zip`. Select `text.html.derivative` and
`tests/fixtures/html/features.html`. The reference tool removes synthetic
newline tokens and converts UTF-16 positions to visible UTF-8 byte ranges.
