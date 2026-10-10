import std/[json, os, sequtils, strutils, unittest]

import pkg/zippy/crc

import matter
import matter/grammarloader

const
  root = currentSourcePath.parentDir.parentDir
  htmlSource = staticRead("fixtures/html/features.html")
  cssSource = staticRead("fixtures/css/css.tmLanguage.json")

suite "HTML TextMate grammar":
  test "loads embedded CSS and JavaScript from the HTML package alone":
    let registry = newRegistry()
    let loaded =
      registry.loadGrammarPackage(zipResourceSource(root), "text.html.derivative")
    check "source.css" in loaded.loadedScopeNames
    check "source.js" in loaded.loadedScopeNames
    let grammar = registry.loadGrammar("text.html.derivative")
    let css = grammar.tokenizeLine("<style>body { color: red; }</style>")
    check css.tokens.anyIt("support.type.property-name.css" in it.scopes)
    let js = grammar.tokenizeLine("<script>const answer = 42;</script>")
    check js.tokens.anyIt("constant.numeric.decimal.js" in it.scopes)

  test "matches VS Code scopes and UTF-8 ranges including embedded CSS and JavaScript":
    let registry = newRegistry()
    registry.addGrammar(parseRawGrammar(cssSource, "css.tmLanguage.json"))
    discard registry.loadGrammarPackage(
      zipResourceSource(root), ["text.html.derivative", "source.js"]
    )
    let grammar = registry.loadGrammar("text.html.derivative")
    let lines = htmlSource.splitLines()
    var
      state: StateStack
      snapshot: string
    for index, line in lines:
      checkpoint("HTML fixture line " & $(index + 1))
      let parsed = grammar.tokenizeLine(line, state)
      check not parsed.stoppedEarly
      state = parsed.completedRuleStack
      snapshot.add($(%parsed.tokens) & "\n")
    check state.depth == 1
    # vscode-textmate 9.2.0 + vscode-oniguruma 2.0.1, with synthetic newlines
    # excluded and UTF-16 reference offsets converted to UTF-8 byte offsets.
    check crc32(snapshot) == 0x1DAE729B'u32
