import std/[sequtils, strutils, unittest]

import matter/[engine, rawgrammar]

proc grammar(source: string): Grammar =
  let registry = newRegistry()
  registry.addGrammar(parseRawGrammar(source, "test.tmLanguage.json"))
  registry.loadGrammar("source.test")

suite "matter engine":
  test "matches in pattern order at the same offset":
    let tested = grammar(
      """
      { "scopeName": "source.test", "patterns": [
        { "match": "x", "name": "first" },
        { "match": "x", "name": "second" }
      ] }
    """
    )
    let result = tokenizeLine(tested, "x")
    check result.tokens.len == 1
    check result.tokens[0].start == 0
    check result.tokens[0].stop == 1
    check result.tokens[0].scopes == @["source.test", "first"]

  test "begin end captures dynamic names and preserves immutable state":
    let tested = grammar(
      """
      { "scopeName": "source.test", "patterns": [{
        "begin": "<(\\w+)>", "end": "</\\1>", "name": "meta.$1",
        "beginCaptures": { "1": { "name": "entity.tag" } },
        "endCaptures": { "0": { "name": "entity.close" } }
      }] }
    """
    )
    let first = tokenizeLine(tested, "<box>text")
    let second = tokenizeLine(tested, "</box>", first.state)
    check first.state != nil
    check first.tokens[0].scopes == @["source.test", "meta.box"]
    check second.tokens[0].scopes == @["source.test", "meta.box", "entity.close"]
    check second.ruleStack != nil
    check second.ruleStack.depth == 1
    check first.state != nil

  test "begin while verifies continuation on each line":
    let tested = grammar(
      """
      { "scopeName": "source.test", "patterns": [{
        "begin": "^>", "while": "^>", "name": "meta.quote",
        "beginCaptures": { "0": { "name": "punctuation.quote" } },
        "whileCaptures": { "0": { "name": "punctuation.quote" } }
      }] }
    """
    )
    let first = tokenizeLine(tested, "> one")
    let second = tokenizeLine(tested, "> two", first.state)
    let third = tokenizeLine(tested, "plain", second.state)
    check first.state != nil
    check second.state != nil
    check third.ruleStack.depth == 1
    check second.tokens[0].scopes == @["source.test", "meta.quote", "punctuation.quote"]

  test "resolves local self base and external includes recursively":
    let registry = newRegistry()
    registry.addGrammar(
      parseRawGrammar(
        """
      { "scopeName": "source.external", "repository": {
        "word": { "match": "z", "name": "external.word" }
      }, "patterns": [{ "include": "#word" }] }
    """,
        "external.json",
      )
    )
    registry.addGrammar(
      parseRawGrammar(
        """
      { "scopeName": "source.test", "repository": {
        "local": { "match": "x", "name": "local.word" },
        "recursive": { "patterns": [
          { "include": "#local" }, { "include": "$self" }, { "include": "$base" }
        ] }
      }, "patterns": [
        { "include": "#recursive" },
        { "include": "source.external#word" }, { "include": "source.external" }
      ] }
    """,
        "main.json",
      )
    )
    let result = tokenizeLine(registry.loadGrammar("source.test"), "xz")
    check result.tokens[0].scopes == @["source.test", "local.word"]
    check result.tokens[1].scopes == @["source.test", "external.word"]

  test "retokenizes capture patterns and applies matching injections":
    let registry = newRegistry()
    registry.addGrammar(
      parseRawGrammar(
        """
      { "scopeName": "source.inject", "injectionSelector": "L:source.test", "patterns": [
        { "match": "!", "name": "injected.bang" }
      ] }
    """,
        "inject.json",
      )
    )
    registry.addGrammar(
      parseRawGrammar(
        """
      { "scopeName": "source.test", "patterns": [{
        "match": "\\[(\\w+)\\]", "captures": {
          "1": { "name": "meta.inner", "patterns": [
            { "match": "word", "name": "keyword.word" }
          ] }
        }
      }] }
    """,
        "main.json",
      )
    )
    let result = tokenizeLine(registry.loadGrammar("source.test"), "[word]!")
    check result.tokens.anyIt("keyword.word" in it.scopes.join(" "))
    check result.tokens[^1].scopes == @["source.test", "injected.bang"]

  test "terminates malformed zero width rules":
    let tested = grammar(
      """
      { "scopeName": "source.test", "patterns": [
        { "match": "(?=x)", "name": "bad.zero" }
      ] }
    """
    )
    let result = tokenizeLine(tested, "x")
    check result.tokens.len <= 2
    check result.tokens[^1].stop == 1

  test "searches child patterns while a begin end rule is active":
    let tested = grammar(
      """
      { "scopeName": "source.test", "patterns": [{
        "begin": "\\[", "end": "\\]", "name": "meta.container",
        "patterns": [{ "match": "x", "name": "keyword.inner" }]
      }] }
    """
    )
    let result = tokenizeLine(tested, "[x]")
    check result.tokens.anyIt("keyword.inner" in it.scopes)
    check result.ruleStack.depth == 1

  test "scans a synthetic newline without emitting it":
    let tested = grammar(
      """
      { "scopeName": "source.test", "patterns": [{
        "begin": "\\n", "end": "x", "name": "meta.synthetic"
      }] }
    """
    )
    let result = tokenizeLine(tested, "")
    check result.tokens.len == 0
    check result.ruleStack.depth == 2

  test "end captures use name scopes instead of content scopes":
    let tested = grammar(
      """
      { "scopeName": "source.test", "patterns": [{
        "begin": "<", "end": ">", "name": "meta.tag", "contentName": "meta.content",
        "endCaptures": { "0": { "name": "punctuation.end" } }
      }] }
    """
    )
    let result = tokenizeLine(tested, "<>")
    check result.tokens[^1].scopes == @["source.test", "meta.tag", "punctuation.end"]

  test "uses nested capture scopes and dynamic case transforms":
    let tested = grammar(
      """
      { "scopeName": "source.test", "patterns": [
        { "match": "((a)b)", "captures": {
          "1": { "name": "outer" }, "2": { "name": "inner" }
        } },
        { "match": "(\\.FOO)", "name": "entity.${1:/downcase}" }
      ] }
    """
    )
    let result = tokenizeLine(tested, "ab .FOO")
    check result.tokens[0].scopes == @["source.test", "outer", "inner"]
    check result.tokens[1].scopes == @["source.test", "outer"]
    check result.tokens[^1].scopes == @["source.test", "entity.foo"]

  test "honors first line and anchor regex semantics":
    let tested = grammar(
      """
      { "scopeName": "source.test", "patterns": [
        { "match": "\\Afirst", "name": "keyword.first" },
        { "begin": "\\[", "end": "\\]", "patterns": [
          { "match": "\\Gx", "name": "keyword.anchored" }
        ] }
      ] }
    """
    )
    let first = tokenizeLine(tested, "first")
    let second = tokenizeLine(tested, "first", first.ruleStack)
    let anchored = tokenizeLine(tested, "[x]", second.ruleStack)
    check first.tokens[0].scopes == @["source.test", "keyword.first"]
    check second.tokens[0].scopes == @["source.test"]
    check anchored.tokens.anyIt("keyword.anchored" in it.scopes)

  test "keeps unanchored alternatives and literal escaped anchors":
    let tested = grammar(
      """
      { "scopeName": "source.test", "patterns": [
        { "match": "\\Gx|y", "name": "keyword.alternative" },
        { "match": "\\\\G", "name": "constant.literalAnchor" }
      ] }
    """
    )
    let result = tokenizeLine(tested, "y \\G")
    check result.tokens[0].scopes == @["source.test", "keyword.alternative"]
    check result.tokens[^1].scopes == @["source.test", "constant.literalAnchor"]

  test "does not let z match before a synthetic newline":
    let tested = grammar(
      """
      { "scopeName": "source.test", "patterns": [{
        "begin": "<", "end": "\\z", "name": "meta.open"
      }] }
    """
    )
    let result = tokenizeLine(tested, "<")
    check result.ruleStack.depth == 2

  test "carries a begin at synthetic eol into while G matching":
    let tested = grammar(
      """
      { "scopeName": "source.test", "patterns": [{
        "begin": "^>\\n", "while": "\\G>", "name": "meta.continued",
        "patterns": [{ "match": "\\Gx", "name": "keyword.afterWhile" }]
      }] }
    """
    )
    let first = tokenizeLine(tested, ">")
    let second = tokenizeLine(tested, ">x", first.ruleStack)
    check first.ruleStack.depth == 2
    check second.tokens.anyIt("keyword.afterWhile" in it.scopes)

  test "keeps the first left injection and supports host registration":
    let registry = newRegistry()
    registry.addGrammar(
      parseRawGrammar(
        """
        { "scopeName": "source.first", "injectionSelector": "L:source.test",
          "patterns": [{ "match": "!", "name": "injected.first" }] }
      """,
        "first.json",
      ),
      ["source.test"],
    )
    registry.addGrammar(
      parseRawGrammar(
        """
        { "scopeName": "source.second", "injectionSelector": "L:source.test",
          "patterns": [{ "match": "!", "name": "injected.second" }] }
      """,
        "second.json",
      ),
      ["source.test"],
    )
    registry.addGrammar(
      parseRawGrammar(
        """
      { "scopeName": "source.test", "patterns": [
        { "match": "!", "name": "normal.bang" }
      ] }
      """,
        "main.json",
      )
    )
    let result = tokenizeLine(registry.loadGrammar("source.test"), "!")
    check result.tokens[0].scopes == @["source.test", "injected.first"]

  test "zero width begin end recovery preserves the active frame":
    let tested = grammar(
      """
      { "scopeName": "source.test", "patterns": [{
        "begin": "(?=x)", "end": "(?=x)", "name": "meta.zero"
      }] }
    """
    )
    let result = tokenizeLine(tested, "x")
    check result.tokens[0].scopes == @["source.test", "meta.zero"]
    check result.ruleStack.depth == 2

  test "time limits stop a sufficiently large tokenization":
    let tested = grammar(
      """
      { "scopeName": "source.test", "patterns": [
        { "match": "x", "name": "constant.x" }
      ] }
    """
    )
    let result = tokenizeLine(tested, "x".repeat(100_000), timeLimitMs = 1)
    check result.stoppedEarly
    check result.ruleStack.depth == 1

  test "the default time limit is unlimited":
    let tested = grammar(
      """
      { "scopeName": "source.test", "patterns": [
        { "match": "x", "name": "constant.x" }
      ] }
    """
    )
    let input = "x".repeat(100_000)
    let result = tokenizeLine(tested, input)
    check not result.stoppedEarly
    check result.tokens[^1].endIndex == input.len

  test "reni match limits are Matter errors":
    let tested = grammar(
      """
      { "scopeName": "source.test", "patterns": [
        { "match": "(a+)+b", "name": "bad.redos" }
      ] }
    """
    )
    expect MatterError:
      discard tokenizeLine(tested, "a".repeat(30))
