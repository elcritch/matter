import std/[tables, unittest]

import matter/rawgrammar

const jsonGrammar =
  """
{
  "scopeName": "source.example",
  "name": "Example",
  "fileTypes": ["example"],
  "patterns": [{"include": "#main"}],
  "repository": {
    "main": {
      "begin": "(\\[)",
      "end": "(\\])",
      "applyEndPatternLast": true,
      "captures": {"1": {"name": "punctuation.definition.example"}},
      "beginCaptures": {},
      "patterns": [{"match": "\\w+", "name": "word.example"}]
    }
  },
  "injections": {"L:comment": {"match": "TODO", "name": "keyword.todo"}}
}
"""

const plistGrammar =
  """
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>scopeName</key><string>source.example</string>
  <key>name</key><string>Example</string>
  <key>fileTypes</key><array><string>example</string></array>
  <key>patterns</key><array><dict><key>include</key><string>#main</string></dict></array>
  <key>repository</key><dict><key>main</key><dict>
    <key>begin</key><string>(\[)</string>
    <key>end</key><string>(\])</string>
    <key>applyEndPatternLast</key><integer>1</integer>
    <key>captures</key><dict><key>1</key><dict><key>name</key><string>punctuation.definition.example</string></dict></dict>
    <key>beginCaptures</key><dict></dict>
    <key>patterns</key><array><dict><key>match</key><string>\w+</string><key>name</key><string>word.example</string></dict></array>
  </dict></dict>
  <key>injections</key><dict><key>L:comment</key><dict><key>match</key><string>TODO</string><key>name</key><string>keyword.todo</string></dict></dict>
</dict></plist>
"""

suite "raw grammar parsing":
  test "JSON and plist produce equivalent grammar data":
    let json = parseRawGrammar(jsonGrammar, "example.tmLanguage.json")
    let plist = parseRawGrammar(plistGrammar, "example.tmLanguage")
    check json.scopeName == plist.scopeName
    check json.name == plist.name
    check json.fileTypes == plist.fileTypes
    check json.patterns.len == 1
    check json.patterns[0].`include` == "#main"
    check plist.patterns[0].`include` == "#main"
    let jsonRule = json.repository["main"]
    let plistRule = plist.repository["main"]
    check jsonRule.begin == plistRule.begin
    check jsonRule.`end` == plistRule.`end`
    check jsonRule.applyEndPatternLast
    check plistRule.applyEndPatternLast
    check jsonRule.hasCaptures
    check jsonRule.captures.hasKey(1)
    check jsonRule.hasBeginCaptures
    check jsonRule.beginCaptures.len == 0
    check plistRule.hasBeginCaptures
    check plistRule.beginCaptures.len == 0
    check jsonRule.patterns[0].match == plistRule.patterns[0].match
    check json.injections["L:comment"].name == plist.injections["L:comment"].name

  test "invalid roots and rules are rejected":
    expect RawGrammarError:
      discard parseRawGrammar("[]", "bad.json")
    expect RawGrammarError:
      discard parseRawGrammar("{\"scopeName\": \"source.bad\"}", "bad.json")
    expect RawGrammarError:
      discard parseRawGrammar(
        "{\"scopeName\": \"source.bad\", \"patterns\": [true]}", "bad.json"
      )

  test "invalid capture map shapes are rejected":
    expect RawGrammarError:
      discard parseRawGrammar(
        "{\"scopeName\": \"source.bad\", \"patterns\": [{\"captures\": []}]}",
        "bad.json",
      )
  test "nonnumeric capture keys are ignored like vscode-textmate":
    let raw = parseRawGrammar(
      "{\"scopeName\": \"source.compat\", \"patterns\": [{\"captures\": {\"one\": {}, \"1\": {\"name\": \"capture\"}}}]}",
      "compat.json",
    )
    check raw.patterns[0].captures.len == 1
    check raw.patterns[0].captures.hasKey(1)

  test "invalid plist values and entity declarations are rejected":
    expect RawGrammarError:
      discard parseRawGrammar("<plist><array/></plist>", "bad.tmLanguage")
    expect RawGrammarError:
      discard parseRawGrammar(
        "<plist><dict><key>scopeName</key><integer>1</integer></dict></plist>",
        "bad.tmLanguage",
      )
    expect RawGrammarError:
      discard parseRawGrammar(
        "<!ENTITY x SYSTEM \"file:///etc/passwd\"><plist><dict/></plist>",
        "bad.tmLanguage",
      )
