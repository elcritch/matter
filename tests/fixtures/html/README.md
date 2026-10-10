# HTML fixtures and exported scopes

`merenda.html` is copied unchanged from `examples/html_ui_demo.html` in Merenda
at commit `f9fe7497fad947aae3ef62ef12b1bbb921496839`. Its SHA-256 is
`afa79306c83011a0796657c6ae45b6141c950002c64618ada40e339045efadf5`.
The BSD 3-Clause license is retained in
[../css/MERENDA-LICENSE.txt](../css/MERENDA-LICENSE.txt). Its 64 source lines
produce 65 tokenizer calls, including the trailing empty line.

`coverage.html` is authored for Matter. It covers tag families, custom elements,
attributes, entities, Unicode, comments, XML declarations, doctypes, CDATA, SVG,
MathML, embedded CSS/JavaScript, malformed inline handlers, and following markup.
Its 80 source lines produce 81 calls. `features.html` retains the earlier
comparison with the Kosmo CSS grammar in `../css/css.tmLanguage.json`.

## Public classes and metadata

Importing `matter` exports `htmlGrammar` (`text.html.derivative`),
`htmlBasicGrammar` (`text.html.basic`), and `vscodeHtmlPackage`. Package loading
registers all six bundled transitive grammars with no unresolved includes.
`Token.scopes` retains every enclosing scope and delimiter class in order.
Use the full path when styling a token; useful selectors include:

| Construct | Scope or selector |
| --- | --- |
| Tag names | `entity.name.tag.html` |
| Structural / inline / void tags | `meta.tag.structure`, `meta.tag.inline`, `meta.tag.object` |
| Custom / unrecognized tags | `meta.tag.custom`, `meta.tag.other.unrecognized.html.derivative` |
| Attribute names / values | `entity.other.attribute-name.html`, `string.quoted.double.html`, `string.quoted.single.html`, `string.unquoted.html` |
| Data attributes / event handlers | `meta.attribute.data-x`, `meta.attribute.event-handler` |
| Entities | `constant.character.entity.named`, `constant.character.entity.numeric.decimal.html`, `constant.character.entity.numeric.hexadecimal.html` |
| Comments | `comment.block.html` |
| Doctype / processing instructions / CDATA | `meta.tag.metadata.doctype.html`, `meta.tag.metadata.processing.xml.html`, `meta.tag.metadata.cdata.html` |
| SVG / MathML | `meta.element.object.svg`, `meta.element.inline.math` |
| Delimiters | `punctuation.definition.tag.begin.html`, `punctuation.definition.tag.end.html`, `punctuation.separator.key-value.html`, `punctuation.definition.entity.html` |
| Deprecated / invalid markup | `invalid.deprecated.html`, `invalid.deprecated.entity.other.attribute-name.html`, `invalid.illegal.bad-angle-bracket.html` |
| Embedded CSS / JavaScript | `source.css`, `source.js`, plus each embedded grammar's scopes |

Selectors match scope prefixes. For example, the full SVG path class is
`meta.element.object.svg.path.html`. The grammar also emits contextual classes
such as `meta.attribute.data-x.data-state.html` and
`meta.attribute.event-handler.click.html`.

```nim
import std/os
import matter
import matter/grammarloader

let registry = newRegistry()
discard registry.loadGrammarPackage(zipResourceSource(getCurrentDir()), "text.html.derivative")
let grammar = registry.loadGrammar("text.html.derivative")
for token in grammar.tokenizeLine("<a href=\"/\">&amp;</a>").tokens:
  echo token.startIndex, "..", token.endIndex, " ", token.scopes
```

`tokenizeLine2` applies theme colors and all four exported font styles (bold,
italic, underline, strikethrough). Configure `embeddedLanguages` with selectors
`source.css` and `source.js` to expose embedded language IDs in binary metadata.
The bundled JavaScript grammar names regex literals `string.regexp.js`, so the
default token type is `String`; a `TokenTypeOverride` can map that selector to
`StandardTokenType.RegEx`. The scope path retains the regex class either way.

On empty lines, inspect `completedRuleStack.activeScopes` or `hasActiveScope`.
Saved stacks and stack diffs preserve HTML attributes, comments, CSS, and
JavaScript contexts without changing earlier stacks.

## Grammar limits

These tests preserve the pinned upstream grammar's behavior. Inline `style`
values receive `source.css` without the detailed property classes emitted in a
`<style>` block. Some attributes, including ARIA attributes, use the grammar's
unrecognized-attribute fallback. Highlighting scopes do not validate HTML.

`host-boundaries.html` isolates an upstream recovery limitation: an unterminated
JavaScript string at `</script>` can leave subsequent HTML scoped as JavaScript.
VS Code produces the same scopes and saved state. Malformed inline event
handlers are different: their capture boundary terminates retokenization, so a
following `id` attribute retains HTML scopes.

Check `stoppedEarly` for calls with a time limit. The checked-in coverage and
Merenda fixtures complete under the existing 10,000-step regex cap. An
interrupted result does not provide a reusable next-line state.

## Benchmark and reference reproduction

```sh
nim c -d:release --path:src -o:/tmp/bench_html tools/bench_html.nim
/tmp/bench_html 3
/tmp/bench_html 3 100
/tmp/bench_html 1 0 /tmp/html-matter.jsonl tests/fixtures/html/coverage.html
```

Arguments are passes, per-line time limit in milliseconds (`0` means unlimited),
optional snapshot path, optional HTML path, and optional scope name. The default
scope is `text.html.derivative`; pass `text.html.basic` to exercise the other
root. See [BENCHMARK.md](BENCHMARK.md) for measurements and profiling findings.

`thtmlgrammar.nim` runs offline, comparing every visible UTF-8 token range and
scope path with `vscode-textmate@9.2.0` and `vscode-oniguruma@2.0.1`. To recreate
the reference, install and extract the bundled grammars using the commands in
the [Markdown fixture guide](../markdown/README.md#benchmark-and-reference-reproduction),
then run:

```sh
NODE_PATH=/tmp/matter-tm-reference/node_modules node tools/reference_tokens.cjs \
  /tmp/matter-reference-grammars text.html.derivative \
  tests/fixtures/html/coverage.html /tmp/html-reference.jsonl
cmp /tmp/html-reference.jsonl /tmp/html-matter.jsonl
```

The helper excludes synthetic-newline tokens and converts UTF-16 positions to
UTF-8 byte offsets. Expected CRC32 values are `E4417669` for coverage with the
derivative root, `37A3741D` for coverage with the basic root, `CAC2C77A` for
Merenda, and `DF5C509F` for the isolated host-boundary case.
