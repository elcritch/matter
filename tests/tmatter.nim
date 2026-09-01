import std/unittest

import matter

const sampleGrammar =
  """
{
  "scopeName": "source.example",
  "patterns": [{
    "begin": "/\\*", "end": "\\*/", "name": "comment.block.example"
  }]
}
"""

suite "matter public API":
  test "documents parsing registration and multiline state":
    let raw = parseRawGrammar(sampleGrammar, "example.tmLanguage.json")
    let registry = newRegistry()
    registry.addGrammar(raw)
    let grammar = registry.loadGrammar("source.example")

    let first = grammar.tokenizeLine("/* open")
    let second = grammar.tokenizeLine("close */", first.ruleStack)

    check first.ruleStack != nil
    check first.tokens[^1].scopes == @["source.example", "comment.block.example"]
    check second.ruleStack.depth == 1
    check second.tokens[^1].startIndex == 0
    check second.tokens[^1].endIndex == 8
    check second.tokens[^1].scopes == @["source.example", "comment.block.example"]

  test "reports malformed grammar text as a catchable parse error":
    expect RawGrammarError:
      discard parseRawGrammar("{", "invalid.tmLanguage.json")

  test "reports invalid grammar regexes as a catchable compilation error":
    let raw = parseRawGrammar(
      """{
        "scopeName": "source.invalid",
        "patterns": [{"match": "("}]
      }""",
      "invalid.tmLanguage.json",
    )
    let registry = newRegistry()
    registry.addGrammar(raw)
    expect MatterError:
      discard registry.loadGrammar("source.invalid")

  test "reexports themes binary metadata fonts and state diffs":
    let raw = parseRawGrammar(
      """{
        "scopeName": "source.themed",
        "patterns": [{"match": "word", "name": "keyword.example"}]
      }""",
      "themed.tmLanguage.json",
    )
    let rawTheme = parseRawTheme(
      """{"settings": [
        {"settings": {"foreground": "#101010", "background": "#202020"}},
        {"scope": "keyword.example", "settings": {
          "foreground": "#303030", "fontStyle": "italic", "fontFamily": "Example Mono"
        }}
      ]}""",
      "themed.tmTheme.json",
    )
    let registry = newRegistry()
    registry.setTheme(rawTheme)
    registry.addGrammar(raw)
    let configuration = GrammarConfiguration(
      initialLanguageId: 7,
      tokenTypes:
        @[
          TokenTypeOverride(
            selector: "keyword.example", tokenType: StandardTokenType.String
          )
        ],
    )
    let grammar = registry.loadGrammar("source.themed", configuration)
    let binary = grammar.tokenizeLine2("word")

    check binary.tokens.len == 2
    check binary.tokens[0] == 0'u32
    let metadata = binary.tokens[1]
    check metadata.getLanguageId() == 7
    check metadata.getTokenType() == StandardTokenType.String
    check metadata.getForeground() > 0
    check metadata.getBackground() > 0
    check metadata.getFontStyle().contains(fontStyleItalic)
    check binary.fonts.len == 1
    check binary.fonts[0].fontFamily == "Example Mono"

    let next = grammar.tokenizeLine("word", binary.ruleStack)
    let diff = diffStateStacksRefEq(binary.ruleStack, next.ruleStack)
    check binary.ruleStack.applyStateStackDiff(diff) == next.ruleStack
