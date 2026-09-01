## Matter parses and tokenizes TextMate grammars for native Nim applications.
##
## Use `parseRawGrammar` to read a JSON or XML plist grammar, add it to a
## `Registry`, then call `tokenizeLine` with the previous result's `ruleStack`
## to tokenize successive lines. Tokens contain half-open UTF-8 byte offsets
## and their outer-to-inner scope paths.
##
## `parseRawGrammar` raises `RawGrammarError` for invalid grammar text. Registry
## and compilation failures raise `MatterError`; both errors are catchable.
##
## Matter currently exposes plain scope tokens. Themes and packed binary token
## metadata are planned for a later compatibility layer.

import matter/[engine, rawgrammar, selectors]

export engine, rawgrammar, selectors
