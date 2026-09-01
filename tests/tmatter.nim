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
