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

The current API returns plain scope tokens only. Theme parsing and
`tokenizeLine2`-style packed binary metadata tokens are planned for Phase 5.
