import std/[json, sequtils, strutils, unittest]

import pkg/zippy/crc

import matter

const
  cssGrammarSource = staticRead("fixtures/css/css.tmLanguage.json")
  cssThemeSource = staticRead("fixtures/css/synthwave83.css")

proc cssGrammar(): Grammar =
  let registry = newRegistry()
  registry.addGrammar(parseRawGrammar(cssGrammarSource, "css.tmLanguage.json"))
  registry.loadGrammar("source.css")

proc checkScope(parsed: TokenizeLineResult, source, fragment, scope: string) =
  checkpoint("Expected " & scope & " on " & fragment)
  let start = source.find(fragment)
  require start >= 0
  for offset in start ..< start + fragment.len:
    check parsed.tokens.anyIt(
      it.startIndex <= offset and offset < it.endIndex and scope in it.scopes
    )

suite "CSS TextMate grammar":
  test "matches VS Code scopes and ranges throughout the Merenda theme":
    let grammar = cssGrammar()
    for limit in [0, 10_000]:
      var
        state: StateStack
        snapshot: string
        tokenCount: int
      for line in cssThemeSource.splitLines():
        let parsed = grammar.tokenizeLine(line, state, limit)
        require not parsed.stoppedEarly
        state = parsed.completedRuleStack
        tokenCount += parsed.tokens.len
        snapshot.add($(%parsed.tokens) & "\n")
      check state.depth == 1
      check tokenCount == 5534
      # Recorded with vscode-textmate 9.2.0 and vscode-oniguruma 2.0.1; covers
      # every visible UTF-8 range and scope in the full document. The positive
      # wall-clock budget also enables the unchanged per-regex step limit.
      check crc32(snapshot) == 0x290396D3'u32

  test "recognizes custom properties gradients scientific notation and percentages":
    let grammar = cssGrammar()
    let first = grammar.tokenizeLine(":root {")
    let line = "  --fill: linear-gradient(to right, #ff00ff, rgba(255, 8%, 86%, 0.94));"
    let parsed = grammar.tokenizeLine(line, first.completedRuleStack)
    checkScope(parsed, line, "--fill", "variable.css")
    checkScope(parsed, line, "linear-gradient", "support.function.gradient.css")
    checkScope(parsed, line, "#ff00ff", "constant.other.color.rgb-value.hex.css")
    checkScope(parsed, line, "8%", "constant.numeric.css")
    let shadow = "  --shadow: 0px 1px 1e+01px 0px var(--fill);"
    let shadowTokens = grammar.tokenizeLine(shadow, parsed.completedRuleStack)
    checkScope(shadowTokens, shadow, "1e+01px", "constant.numeric.css")
    checkScope(shadowTokens, shadow, "var", "support.function.misc.css")
