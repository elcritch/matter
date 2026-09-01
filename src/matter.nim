## Matter parses, themes, and tokenizes TextMate grammars for native Nim applications.
##
## Use `parseRawGrammar` to read a JSON or XML plist grammar, add it to a
## `Registry`, then call `tokenizeLine` with the previous result's `ruleStack`
## to tokenize successive lines. Plain tokens contain half-open UTF-8 byte
## offsets and their outer-to-inner scope paths. `tokenizeLine2` additionally
## emits alternating UTF-8 byte offsets and packed metadata.
##
## `parseRawGrammar` raises `RawGrammarError` for invalid grammar text. Registry
## and compilation failures raise `MatterError`; both errors are catchable.
##
## Use `parseRawTheme` and `setTheme` to apply TextMate theme settings. The
## `metadata` API provides stable field accessors for binary token values.
## `grammarpackages` exposes pinned Open VSX grammar metadata and direct URLs.
## `grammarassets` exposes the corresponding Matter ZIP release assets and
## pure helpers to choose a Matter release or the pinned upstream VSIX.

import
  matter/
    [engine, grammarassets, grammarpackages, metadata, rawgrammar, selectors, theme]

export engine, grammarassets, grammarpackages, metadata, rawgrammar, selectors, theme
