import std/[assertions, unittest]

import matter/[engine, rawgrammar]

proc compileGrammar(source: string): Grammar =
  let registry = newRegistry()
  registry.addGrammar(parseRawGrammar(source, "compat.tmLanguage.json"))
  registry.loadGrammar("source.compat")

proc tokenAt(tokens: openArray[Token], index: int): Token =
  for token in tokens:
    if token.startIndex <= index and index < token.endIndex:
      return token
  doAssert false, "expected a token at byte offset " & $index
  Token()

proc hasScope(token: Token, scope: string): bool =
  for candidate in token.scopes:
    if candidate == scope:
      return true
  false

suite "vscode-textmate compatibility":
  test "inner patterns tokenize begin-end content":
    let tested = compileGrammar(
      """
      { "scopeName": "source.compat", "patterns": [{
        "begin": "\\[", "end": "\\]", "name": "meta.block",
        "patterns": [{ "match": "x", "name": "constant.inner" }]
      }] }
    """
    )
    let result = tokenizeLine(tested, "[x]")
    doAssert tokenAt(result.tokens, 0).scopes == @["source.compat", "meta.block"]
    doAssert tokenAt(result.tokens, 1).scopes ==
      @["source.compat", "meta.block", "constant.inner"]
    doAssert tokenAt(result.tokens, 2).scopes == @["source.compat", "meta.block"]

  test "synthetic newline closes rules without producing a token":
    let tested = compileGrammar(
      """
      { "scopeName": "source.compat", "patterns": [{
        "begin": "\\[", "end": "\\n", "name": "meta.line"
      }] }
    """
    )
    let first = tokenizeLine(tested, "[")
    doAssert first.tokens.len == 1
    doAssert first.tokens[0].startIndex == 0
    doAssert first.tokens[0].endIndex == 1
    doAssert first.tokens[0].scopes == @["source.compat", "meta.line"]
    let second = tokenizeLine(tested, "]", first.ruleStack)
    doAssert second.tokens[0].scopes == @["source.compat"]

  test "a begin-end state survives an empty line":
    let tested = compileGrammar(
      """
      { "scopeName": "source.compat", "patterns": [{
        "begin": "<", "end": ">", "name": "meta.multiline"
      }] }
    """
    )
    let first = tokenizeLine(tested, "<")
    let empty = tokenizeLine(tested, "", first.ruleStack)
    let closed = tokenizeLine(tested, ">", empty.ruleStack)
    doAssert closed.tokens.len == 1
    doAssert closed.tokens[0].scopes == @["source.compat", "meta.multiline"]

  test "content names exclude end delimiters":
    let tested = compileGrammar(
      """
      { "scopeName": "source.compat", "patterns": [{
        "begin": "\\[", "end": "\\]", "name": "meta.block",
        "contentName": "string.content"
      }] }
    """
    )
    let result = tokenizeLine(tested, "[x]")
    doAssert tokenAt(result.tokens, 0).scopes == @["source.compat", "meta.block"]
    doAssert tokenAt(result.tokens, 1).scopes ==
      @["source.compat", "meta.block", "string.content"]
    doAssert tokenAt(result.tokens, 2).scopes == @["source.compat", "meta.block"]

  test "nested capture scopes overlay their enclosing captures":
    let tested = compileGrammar(
      """
      { "scopeName": "source.compat", "patterns": [{
        "match": "(a(bc))", "name": "meta.rule",
        "captures": {
          "1": { "name": "meta.outer" },
          "2": { "name": "meta.inner" }
        }
      }] }
    """
    )
    let result = tokenizeLine(tested, "abc")
    doAssert tokenAt(result.tokens, 0).scopes ==
      @["source.compat", "meta.rule", "meta.outer"]
    doAssert tokenAt(result.tokens, 1).scopes ==
      @["source.compat", "meta.rule", "meta.outer", "meta.inner"]

  test "applyEndPatternLast lets an inner pattern win an equal-offset tie":
    let normal = compileGrammar(
      """
      { "scopeName": "source.compat", "patterns": [{
        "begin": "\\[", "end": "\\]", "name": "meta.block",
        "contentName": "meta.content",
        "patterns": [{ "match": "\\]", "name": "constant.inner" }]
      }] }
    """
    )
    let delayed = compileGrammar(
      """
      { "scopeName": "source.compat", "patterns": [{
        "begin": "\\[", "end": "\\]", "name": "meta.block",
        "contentName": "meta.content", "applyEndPatternLast": true,
        "patterns": [{ "match": "\\]", "name": "constant.inner" }]
      }] }
    """
    )
    let normalToken = tokenAt(tokenizeLine(normal, "[]").tokens, 1)
    let delayedToken = tokenAt(tokenizeLine(delayed, "[]").tokens, 1)
    doAssert not normalToken.hasScope("constant.inner")
    doAssert delayedToken.hasScope("meta.content")
    doAssert delayedToken.hasScope("constant.inner")

  test "dynamic names support downcase and upcase transforms":
    let tested = compileGrammar(
      """
      { "scopeName": "source.compat", "patterns": [{
        "match": "([A-Za-z]+)-([A-Za-z]+)",
        "name": "meta.${1:/upcase}.${2:/downcase}"
      }] }
    """
    )
    let result = tokenizeLine(tested, "AbC-XyZ")
    doAssert result.tokens[0].scopes == @["source.compat", "meta.ABC.xyz"]

  test "the A anchor is available only on the first tokenized line":
    let tested = compileGrammar(
      """
      { "scopeName": "source.compat", "patterns": [
        { "match": "\\Afirst", "name": "anchor.first" }
      ] }
    """
    )
    let first = tokenizeLine(tested, "first")
    let second = tokenizeLine(tested, "first", first.ruleStack)
    doAssert first.tokens[0].scopes == @["source.compat", "anchor.first"]
    doAssert second.tokens[0].scopes == @["source.compat"]

  test "the G anchor applies only at a begin rule anchor position":
    let tested = compileGrammar(
      """
      { "scopeName": "source.compat", "patterns": [{
        "begin": "\\[", "end": "\\]", "name": "meta.block",
        "patterns": [{ "match": "\\Gx", "name": "anchor.g" }]
      }] }
    """
    )
    let result = tokenizeLine(tested, "[xx]")
    doAssert tokenAt(result.tokens, 1).hasScope("anchor.g")
    doAssert not tokenAt(result.tokens, 2).hasScope("anchor.g")

  test "the root rule stack is always available":
    let tested = compileGrammar("""{ "scopeName": "source.compat", "patterns": [] }""")
    let result = tokenizeLine(tested, "plain")
    doAssert result.ruleStack != nil

  test "external base includes return to the host grammar":
    let registry = newRegistry()
    registry.addGrammar(
      parseRawGrammar(
        """
        { "scopeName": "source.external", "repository": {
          "throughBase": { "patterns": [{ "include": "$base" }] }
        }, "patterns": [{ "include": "#throughBase" }] }
      """,
        "external.tmLanguage.json",
      )
    )
    registry.addGrammar(
      parseRawGrammar(
        """
        { "scopeName": "source.compat", "repository": {
          "host": { "match": "h", "name": "host.match" }
        }, "patterns": [
          { "include": "source.external" }, { "include": "#host" }
        ] }
      """,
        "host.tmLanguage.json",
      )
    )
    let result = tokenizeLine(registry.loadGrammar("source.compat"), "h")
    doAssert result.tokens[0].scopes == @["source.compat", "host.match"]

  test "an injection selector matches the active nested scope path":
    let tested = compileGrammar(
      """
      { "scopeName": "source.compat", "patterns": [{
        "begin": "\\[", "end": "\\]", "name": "meta.host",
        "patterns": [{ "match": "!", "name": "base.bang" }]
      }], "injections": {
        "L:source.compat meta.host": {
          "match": "!", "name": "injected.bang"
        }
      } }
    """
    )
    let result = tokenizeLine(tested, "[!]")
    doAssert tokenAt(result.tokens, 1).hasScope("injected.bang")

  test "zero-width begin-end recovery preserves the active frame":
    let tested = compileGrammar(
      """
      { "scopeName": "source.compat", "patterns": [{
        "begin": "(?=x)", "end": "(?=x)", "name": "meta.zero"
      }] }
    """
    )
    let result = tokenizeLine(tested, "x")
    doAssert result.tokens[0].scopes == @["source.compat", "meta.zero"]
    doAssert result.ruleStack.depth == 2

  test "left, default, and right injection ties preserve priority":
    let left = compileGrammar(
      """
      { "scopeName": "source.compat", "patterns": [
        { "match": "x", "name": "base" }
      ], "injections": {
        "L:source.compat": { "match": "x", "name": "injection.left" },
        "source.compat": { "match": "x", "name": "injection.default" },
        "R:source.compat": { "match": "x", "name": "injection.right" }
      } }
    """
    )
    let default = compileGrammar(
      """
      { "scopeName": "source.compat", "patterns": [], "injections": {
        "source.compat": { "match": "x", "name": "injection.default" },
        "R:source.compat": { "match": "x", "name": "injection.right" }
      } }
    """
    )
    let right = compileGrammar(
      """
      { "scopeName": "source.compat", "patterns": [
        { "match": "x", "name": "base" }
      ], "injections": {
        "R:source.compat": { "match": "x", "name": "injection.right" }
      } }
    """
    )
    doAssert tokenAt(tokenizeLine(left, "x").tokens, 0).hasScope("injection.left")
    doAssert tokenAt(tokenizeLine(default, "x").tokens, 0).hasScope("injection.default")
    doAssert tokenAt(tokenizeLine(right, "x").tokens, 0).hasScope("base")
