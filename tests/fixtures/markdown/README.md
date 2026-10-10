# Markdown fixtures and exported scopes

`merenda.md` is copied unchanged from
`tests/kosmo/fixtures/markdown-activation.md` in Merenda at commit
`bcc773a0966a77a6f6538e097be608d36a63bf4c`. Its SHA-256 is
`08900baf9da253c8c44a937263d93dffc1a111b3dabe39f9282fce80b3e0cbe9`.
It contains 575 newline-terminated lines of technical documentation, including
headings, lists, links, inline code, and fenced blocks. Merenda's BSD 3-Clause
license is retained in [../css/MERENDA-LICENSE.txt](../css/MERENDA-LICENSE.txt).

`features.md` is authored for Matter and exercises all heading levels, setext
headings, emphasis, strikethrough, links/images, references, escapes, Unicode,
quotes, nested lists, tasks, tables, separators, front matter, indented code,
HTML, and fenced CSS/JavaScript/unknown languages. Its 71 source lines produce
72 tokenizer calls including the trailing empty line. The benchmark similarly
counts 576 lines in `merenda.md`.

## Available scope classes

Importing `matter` exposes `Token` and its `scopes` field. Scope paths retain
every enclosing scope and delimiter class in outer-to-inner order; inspect the
whole path rather than just its last entry. The bundled Markdown grammar emits:

| Construct | Scope or selector |
| --- | --- |
| ATX headings | `markup.heading.markdown`, `heading.1.markdown` through `heading.6.markdown` |
| Setext headings | `markup.heading.setext.1.markdown`, `markup.heading.setext.2.markdown` |
| Bold / italic / strikethrough | `markup.bold.markdown`, `markup.italic.markdown`, `markup.strikethrough.markdown` |
| Inline code / indented code | `markup.inline.raw.string.markdown`, `markup.raw.block.markdown` |
| Links / images | `markup.underline.link.markdown`, `markup.underline.link.image.markdown` |
| Inline links / reference links / email | `meta.link.inline.markdown`, `meta.link.reference.markdown`, `meta.link.email.lt-gt.markdown` |
| Quotes | `markup.quote.markdown` |
| Ordered / unordered lists | `markup.list.numbered.markdown`, `markup.list.unnumbered.markdown` |
| Tables / horizontal separators | `markup.table.markdown`, `meta.separator.markdown` |
| Fenced blocks | `markup.fenced_code.block.markdown` |
| Fence language names | `fenced_code.block.language`, `fenced_code.block.language.markdown` |
| Embedded CSS / JavaScript | `meta.embedded.block.css`, `meta.embedded.block.javascript`, plus the embedded grammar's scopes |
| YAML front matter | `meta.embedded.block.frontmatter`, plus YAML scopes |
| Delimiters | `punctuation.definition.heading.markdown`, `punctuation.definition.list.begin.markdown`, `punctuation.definition.quote.begin.markdown`, link and fence punctuation |

These are TextMate scope strings, usable directly as theme selectors. For
example, a theme rule with scope `markup.bold` applies to Markdown bold tokens.
`tokenizeLine2` exposes the resulting font styles through `getFontStyle` and
`fontStyleBold`, `fontStyleItalic`, `fontStyleUnderline`, and
`fontStyleStrikethrough`. Regression tests apply all four styles through the
public `matter` import.

```nim
import std/os
import matter
import matter/grammarloader

let registry = newRegistry()
discard registry.loadGrammarPackage(zipResourceSource(getCurrentDir()), "text.html.markdown")
let grammar = registry.loadGrammar("text.html.markdown")
for token in grammar.tokenizeLine("# A **bold** heading").tokens:
  if "markup.bold.markdown" in token.scopes:
    echo token.startIndex, "..", token.endIndex, " ", token.scopes
```

For empty lines, inspect `completedRuleStack.activeScopes` or
`hasActiveScope("markup.fenced_code")`. An unknown fenced language retains the
Markdown block scopes. Register extra languages before loading Markdown to
enable Matter's runtime fence dispatch.

## Benchmark and reference reproduction

```sh
nim c -d:release --path:src -o:/tmp/bench_markdown tools/bench_markdown.nim
/tmp/bench_markdown 3
/tmp/bench_markdown 1 100
/tmp/bench_markdown 1 0 /tmp/markdown-matter.jsonl tests/fixtures/markdown/features.md
```

Arguments are passes, per-line time limit in milliseconds (`0` means unlimited),
optional token snapshot path, and optional Markdown path. Compilation includes
package loading; document timings exclude both and include snapshot serialization.
See [BENCHMARK.md](BENCHMARK.md) for measurements and profiling findings.

`tmarkdowngrammar.nim` compares every visible token range and scope against
`vscode-textmate@9.2.0` with `vscode-oniguruma@2.0.1`, using all bundled grammars.
Tests run offline in Nim. To recreate the reference:

```sh
npm install --prefix /tmp/matter-tm-reference --ignore-scripts --no-audit --no-fund \
  vscode-textmate@9.2.0 vscode-oniguruma@2.0.1
python3 - <<'PY'
from pathlib import Path
from zipfile import ZipFile
out = Path('/tmp/matter-reference-grammars')
out.mkdir(exist_ok=True)
for archive in sorted(Path('data/grammars').glob('*.zip')):
    with ZipFile(archive) as z:
        for name in z.namelist():
            if name.endswith(('.tmLanguage', '.tmLanguage.json')):
                (out / (archive.stem + '-' + Path(name).name)).write_bytes(z.read(name))
PY
NODE_PATH=/tmp/matter-tm-reference/node_modules node tools/reference_tokens.cjs \
  /tmp/matter-reference-grammars text.html.markdown \
  tests/fixtures/markdown/features.md /tmp/markdown-reference.jsonl
cmp /tmp/markdown-reference.jsonl /tmp/markdown-matter.jsonl
```

The reference helper excludes Matter's runtime-dispatch rule and uses the
upstream static/fallback fence rules. Runtime dispatch has separate loader tests.
It also removes synthetic-newline tokens and converts UTF-16 positions to UTF-8.
Repeat with `merenda.md` for the larger snapshot. Expected CRC32 values are
`9CE9F590` for features and `3C62BA15` for Merenda.
