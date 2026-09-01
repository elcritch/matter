# Matter

Matter is a synchronous TextMate grammar tokenizer for native Nim applications.
It reads JSON and XML plist `.tmLanguage` grammars and emits plain scope tokens
with UTF-8 byte offsets.

## Setup

Matter uses Atlas for dependencies:

```sh
atlas install
atlas-run tests
```

Run the public API smoke test directly when iterating on the example:

```sh
nim r tests/tmatter.nim
```

## Bundled grammar packages

`grammarpackages` contains pinned source, license, archive, and direct-download
metadata for all 35 syntax modes in Moe at commit
`0dcc33b87cf672e727c54d39b48bd81cc68e6c2c`. The stripped, ordinary ZIP
archives live under `data/grammars/`; they retain only allowlisted TextMate
grammar files plus the source package manifest, license, and provenance. They
never need `npx` to download or use.

```nim
import matter

let grammarPackage = vscodeCppPackage
let downloadUrl = grammarPackage.vsixDownloadUrl()
echo downloadUrl
# https://open-vsx.org/api/vscode/cpp/1.95.3/file/vscode.cpp-1.95.3.vsix
for grammar in importedGrammars("cpp"):
  echo grammar.dataArchivePath, ":", grammar.archiveMember
# data/grammars/vscode-cpp-1.95.3.zip:grammar/syntaxes/cpp.tmLanguage.json
```

`importedGrammars("cpp")` yields the primary grammar and the support grammars
from its archive. The catalog includes archive and source VSIX SHA-256 values;
[`data/grammars/NOTICES.md`](data/grammars/NOTICES.md) records the complete
redistribution notice and provenance list.

To refresh pinned source files after intentionally editing
`tools/grammar_manifest.json`, use Python 3 and `nph` (network access required).
The generator invokes `nph` itself so the generated Nim catalog remains formatted:

```sh
nim regenerateGrammars
```

The task rejects a downloaded VSIX whose pinned SHA-256 differs. Verify a clean
checkout without network access with:

```sh
nim verifyGrammars
```

## Parse, register, and tokenize

```nim
import matter

let source = """
{
  "scopeName": "source.example",
  "patterns": [{
    "begin": "/\\*", "end": "\\*/", "name": "comment.block.example"
  }]
}
"""

let raw = parseRawGrammar(source, "example.tmLanguage.json")
let registry = newRegistry()
registry.addGrammar(raw)
let grammar = registry.loadGrammar("source.example")

let first = grammar.tokenizeLine("/* open")
let second = grammar.tokenizeLine("close */", first.ruleStack)

for token in second.tokens:
  echo token.startIndex, "..", token.endIndex, " ", token.scopes
```

Pass the previous result's `ruleStack` to preserve multiline constructs. Omit
that argument (or pass `nil`) to start a new document. Successful results keep
a root `ruleStack`, even after all nested rules close. Each token uses a
half-open UTF-8 byte range, so the end offset is suitable for Nim string
slicing.

## Current scope

Matter supports JSON and XML plist grammars, match and begin/end or begin/while
rules, captures (including nested capture patterns), repositories/includes,
injections, selectors, dynamic capture substitutions, and incremental line
tokenization. `parseRawGrammar` raises `RawGrammarError` for malformed input;
grammar registration and compilation failures raise `MatterError`. Both are
catchable errors.

The API provides both plain scope tokens and theme-aware binary tokens.

## Themes and binary tokens

Parse and apply a TextMate theme before loading a configured grammar:

```nim
let rawTheme = parseRawTheme("""
{"settings": [
  {"settings": {"foreground": "#D4D4D4", "background": "#1E1E1E"}},
  {"scope": "comment.block.example", "settings": {
    "foreground": "#6A9955", "fontStyle": "italic", "fontFamily": "Mono"
  }}
]}
""", "example.tmTheme.json")
registry.setTheme(rawTheme)

let configuration = GrammarConfiguration(
  initialLanguageId: 1,
  tokenTypes: @[
    TokenTypeOverride(
      selector: "comment.block.example", tokenType: StandardTokenType.Comment
    )
  ]
)
let themedGrammar = registry.loadGrammar("source.example", configuration)
let binary = themedGrammar.tokenizeLine2("/* open")

let startIndex = binary.tokens[0]
let metadata = binary.tokens[1]
echo startIndex, " ", getLanguageId(metadata), " ", getTokenType(metadata)
echo getForeground(metadata), " ", getBackground(metadata), " ",
  fontStyleValue(getFontStyle(metadata))
```

`tokenizeLine2` returns alternating `uint32` start offsets and metadata values:
`[start0, metadata0, start1, metadata1, ...]`. Start offsets remain UTF-8 byte
offsets. Its `fonts` sequence contains coalesced font-family, font-size, and
line-height spans. Use `diffStateStacksRefEq` and `applyStateStackDiff` to
transport immutable rule-stack changes between tokenization calls.
