import std/[sequtils, strutils, unittest]

import matter/[engine, rawgrammar]

proc grammar(source: string): Grammar =
  let registry = newRegistry()
  registry.addGrammar(parseRawGrammar(source, "test.tmLanguage.json"))
  registry.loadGrammar("source.test")

suite "matter engine":
  when not defined(useMalloc) and (defined(gcArc) or defined(gcAtomicArc)):
    test "recursive grammar graphs are reclaimed without cycle collection":
      let registry = newRegistry()
      registry.addGrammar(
        parseRawGrammar(
          """
        { "scopeName": "source.recursive", "patterns": [{
          "begin": "\\[", "end": "\\]", "name": "meta.square",
          "patterns": [{ "include": "$self" }],
          "beginCaptures": { "0": { "patterns": [{ "include": "$base" }] } }
        }] }
      """,
          "recursive.json",
        )
      )
      proc compileAndDrop() {.noinline.} =
        discard registry.loadGrammar("source.recursive")

      compileAndDrop()
      let before = getOccupiedMem()
      for _ in 0 ..< 100:
        compileAndDrop()
      check getOccupiedMem() - before < 16_384

    test "failed recursive grammar compilation releases partial graphs":
      proc compileAndDrop(registry: Registry) {.noinline.} =
        try:
          discard registry.loadGrammar("source.invalid")
          doAssert false, "invalid rule must fail to compile"
        except MatterError:
          discard

      for invalidRule in ["""{"matterEmbeddedLanguage":"nim"}""", """{"match":"("}"""]:
        let registry = newRegistry()
        registry.addGrammar(
          parseRawGrammar(
            """{"scopeName":"source.invalid","patterns":[{"include":"$self"},RULE]}""".replace(
              "RULE", invalidRule
            ),
            "invalid.json",
          )
        )
        compileAndDrop(registry)
        let before = getOccupiedMem()
        for _ in 0 ..< 100:
          compileAndDrop(registry)
        check getOccupiedMem() - before < 16_384

    test "regex limit failures release caught exceptions":
      let tested = grammar(
        """
        { "scopeName": "source.test", "patterns": [{ "match": "(a+)+b" }] }
      """
      )
      let source = "a".repeat(30)
      proc tokenizeAndDrop(
          tested: Grammar, source: string, timeLimit: int
      ) {.noinline.} =
        try:
          let parsed = tested.tokenizeLine(source, timeLimitMs = timeLimit)
          doAssert timeLimit > 0 and parsed.stoppedEarly
        except MatterError:
          doAssert timeLimit == 0

      for timeLimit in [0, 10_000]:
        tokenizeAndDrop(tested, source, timeLimit)
        let before = getOccupiedMem()
        for _ in 0 ..< 32:
          tokenizeAndDrop(tested, source, timeLimit)
        check getOccupiedMem() - before < 4096

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

  test "reuses future matches without keeping consumed captures":
    let tested = grammar(
      """
      { "scopeName": "source.test", "patterns": [
        { "match": "(x)(y)", "captures": {
          "1": { "name": "first" }, "2": { "name": "second" }
        } },
        { "match": "\\d", "name": "number" }
      ] }
    """
    )
    let parsed = tested.tokenizeLine("12xy3xy")
    check parsed.tokens.mapIt((it.startIndex, it.endIndex, it.scopes[^1])) ==
      @[
        (0, 1, "number"),
        (1, 2, "number"),
        (2, 3, "first"),
        (3, 4, "second"),
        (4, 5, "number"),
        (5, 6, "first"),
        (6, 7, "second"),
      ]
    let next = tested.tokenizeLine("xy", parsed.completedRuleStack)
    check next.tokens.mapIt(it.scopes[^1]) == @["first", "second"]

  test "rechecks G after entering a begin rule":
    let tested = grammar(
      """
      { "scopeName": "source.test", "patterns": [
        { "include": "#anchored" },
        { "begin": "\\[", "end": "\\]", "patterns": [
          { "include": "#anchored" }
        ] }
      ], "repository": {
        "anchored": { "match": "\\Gx", "name": "anchored" }
      } }
    """
    )
    let parsed = tested.tokenizeLine("[x]")
    check parsed.tokens.anyIt(it.startIndex == 1 and "anchored" in it.scopes)

  test "nearby probes keep G at the original search position inside lookbehinds":
    let tested = grammar(
      """
      { "scopeName": "source.test", "patterns": [{
        "begin": "\\[", "end": "\\]", "patterns": [
          { "match": "(?<=\\Gx)y", "name": "anchored" },
          { "match": "z", "name": "later" }
        ]
      }] }
    """
    )
    let parsed = tested.tokenizeLine("[xyz]")
    check parsed.tokens.anyIt(it.startIndex == 2 and "anchored" in it.scopes)
    check parsed.tokens.anyIt(it.startIndex == 3 and "later" in it.scopes)

  test "zero width begins invalidate G results when only the anchor changes":
    let tested = grammar(
      """
      { "scopeName": "source.test", "patterns": [
        { "include": "#anchored" },
        { "begin": "(?=x)", "end": "(?<=x)", "patterns": [
          { "include": "#anchored" }
        ] }
      ], "repository": {
        "anchored": { "match": "\\Gx", "name": "anchored" }
      } }
    """
    )
    let parsed = tested.tokenizeLine("x")
    check parsed.tokens[0].scopes == @["source.test", "anchored"]

  test "nearby probes preserve longest match searches":
    let tested = grammar(
      """
      { "scopeName": "source.test", "patterns": [
        { "match": "(?L)x+", "name": "longest" },
        { "match": "y", "name": "earlier" }
      ] }
    """
    )
    let parsed = tested.tokenizeLine("xyxxx")
    check parsed.tokens.mapIt((it.startIndex, it.endIndex, it.scopes[^1])) ==
      @[(0, 1, "source.test"), (1, 2, "earlier"), (2, 5, "longest")]

  test "nearby matches avoid scanning an expensive suffix unnecessarily":
    let tested = grammar(
      """
      { "scopeName": "source.test", "patterns": [
        { "match": "(a+)+b", "name": "unmatched" },
        { "match": "x.+", "name": "nearby" }
      ] }
    """
    )
    let source = "  x" & "a".repeat(30)
    let parsed = tested.tokenizeLine(source, timeLimitMs = 10_000)
    check not parsed.stoppedEarly
    check parsed.tokens[^1].scopes == @["source.test", "nearby"]
    check parsed.tokens[^1].endIndex == source.len

  test "nearby probes fall back across long gaps and UTF-8 text":
    let tested = grammar(
      """
      { "scopeName": "source.test", "patterns": [
        { "match": "x", "name": "letter" }
      ] }
    """
    )
    for source in [" ".repeat(40) & "x", "α😀x"]:
      let parsed = tested.tokenizeLine(source)
      check parsed.tokens[^1].startIndex == source.len - 1
      check parsed.tokens[^1].scopes == @["source.test", "letter"]

  test "invalidates cached matches when the cursor passes the consumed start":
    let tested = grammar(
      """
      { "scopeName": "source.test", "patterns": [
        { "match": "a", "name": "first" },
        { "match": "a\\Kb", "name": "kept" }
      ] }
    """
    )
    let parsed = tested.tokenizeLine("ab")
    check parsed.tokens.mapIt(it.scopes[^1]) == @["first", "source.test"]

  test "keeps searching when K in a lookbehind can report an earlier start":
    let tested = grammar(
      """
      { "scopeName": "source.test", "patterns": [
        { "match": "a", "name": "first" },
        { "match": "b", "name": "second" },
        { "match": "(?<=\\Ka)b", "name": "kept" }
      ] }
    """
    )
    let parsed = tested.tokenizeLine("ab")
    check parsed.tokens.anyIt("kept" in it.scopes)
    check not parsed.tokens.anyIt("second" in it.scopes)

  test "does not probe later rules once the first rule wins at the cursor":
    let tested = grammar(
      """
      { "scopeName": "source.test", "patterns": [
        { "match": "a", "name": "first" },
        { "match": "(a+)+b", "name": "pathological" }
      ] }
    """
    )
    # Probing the second rule would exhaust Reni's matching step limit.
    let parsed = tested.tokenizeLine("a".repeat(30))
    check not parsed.stoppedEarly
    check parsed.tokens.len == 30
    check parsed.tokens.allIt(it.scopes == @["source.test", "first"])

  test "splits multiple names in matches captures and begin end content scopes":
    let tested = grammar(
      """
      { "scopeName": "source.test", "patterns": [
        { "match": "(a)", "name": "match.one match.two",
          "captures": { "1": { "name": "capture.one capture.two" } } },
        { "begin": "<", "end": ">", "name": "region.one region.two",
          "contentName": "content.one content.two",
          "patterns": [{ "match": "(b)", "captures": {
            "1": { "name": "capture.outer", "contentName": "retoken.one retoken.two",
              "patterns": [{ "match": "b", "name": "nested.one nested.two" }] }
          } }] }
      ] }
    """
    )
    let parsed = tested.tokenizeLine("a<b>")
    check parsed.tokens[0].scopes ==
      @["source.test", "match.one", "match.two", "capture.one", "capture.two"]
    check parsed.tokens[1].scopes == @["source.test", "region.one", "region.two"]
    check parsed.tokens[2].scopes ==
      @[
        "source.test", "region.one", "region.two", "content.one", "content.two",
        "capture.outer", "retoken.one", "retoken.two", "nested.one", "nested.two",
      ]
    check parsed.tokens[3].scopes == @["source.test", "region.one", "region.two"]

  test "retokenized captures do not inherit overlapping capture names":
    let tested = grammar(
      """
      { "scopeName": "source.test", "patterns": [{
        "match": "(a)b", "name": "match.scope", "captures": {
          "0": { "name": "whole.capture" },
          "1": { "name": "inner.capture", "patterns": [
            { "match": "a", "name": "nested.scope" }
          ] }
        }
      }] }
    """
    )
    let parsed = tested.tokenizeLine("ab")
    check parsed.tokens[0].scopes ==
      @["source.test", "match.scope", "inner.capture", "nested.scope"]
    check parsed.tokens[1].scopes == @["source.test", "match.scope", "whole.capture"]

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

  test "keeps full external grammar roots distinct while compiling":
    let registry = newRegistry()
    for index, letter in ["a", "b", "c", "d"]:
      registry.addGrammar(
        parseRawGrammar(
          """{"scopeName":"source.external.$1","patterns":[{"match":"$2","name":"external.$1"}]}""" %
            [$index, letter],
          "external-" & $index & ".json",
        )
      )
    registry.addGrammar(
      parseRawGrammar(
        """
      { "scopeName": "source.test", "patterns": [
        { "include": "source.external.0" },
        { "include": "source.external.1" },
        { "include": "source.external.2" },
        { "include": "source.external.3" }
      ] }
    """,
        "main.json",
      )
    )
    let result = registry.loadGrammar("source.test").tokenizeLine("abcd")
    check result.tokens.mapIt(it.scopes[^1]) ==
      @["external.0", "external.1", "external.2", "external.3"]

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

  test "allows nested distinct zero width begins before consuming text":
    let tested = grammar(
      """
      { "scopeName": "source.test", "patterns": [{
        "begin": "(?=x)", "end": "(?<=x)", "name": "outer",
        "patterns": [{
          "begin": "(?=x)", "end": "(?<=x)", "name": "inner",
          "patterns": [{ "match": "x", "name": "word" }]
        }]
      }] }
    """
    )
    let parsed = tested.tokenizeLine("x")
    check parsed.tokens[0].scopes == @["source.test", "outer", "inner", "word"]
    check parsed.completedRuleStack.depth == 1

  test "stops recursive zero width begins without blocking distinct rules":
    let tested = grammar(
      """
      { "scopeName": "source.test", "patterns": [{ "include": "#region" }],
        "repository": { "region": {
          "begin": "(?=x)", "end": "(?!)", "name": "region",
          "patterns": [{ "include": "#region" }]
        } }
      }
    """
    )
    let parsed = tested.tokenizeLine("x")
    check parsed.tokens[0].scopes == @["source.test", "region"]
    check parsed.completedRuleStack.depth == 2

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

  test "dispatches registered embedded languages from a dynamic begin capture":
    let registry = newRegistry()
    registry.addGrammar(
      parseRawGrammar(
        """
      { "scopeName": "source.embedded", "patterns": [
        { "match": "\\b(proc|let)\\b", "name": "keyword.embedded" },
        { "begin": "\"", "end": "\"", "name": "string.embedded" }
      ] }
    """,
        "embedded.json",
      )
    )
    registry.registerLanguage("nim", "source.embedded")
    registry.addGrammar(
      parseRawGrammar(
        """
      { "scopeName": "text.host", "patterns": [
        {
          "begin": "```(\\w+)", "end": "```",
          "name": "markup.fenced", "contentName": "meta.embedded.${1:/downcase}",
          "matterEmbeddedLanguage": "${1:/downcase}"
        },
        { "begin": "```\\w+", "end": "```", "name": "markup.fallback" }
      ] }
    """,
        "host.json",
      )
    )
    let host = registry.loadGrammar("text.host")
    let opening = host.tokenizeLine("```NIM")
    let firstBody = host.tokenizeLine("proc answer =", opening.completedRuleStack)
    check firstBody.tokens.anyIt("keyword.embedded" in it.scopes)
    check firstBody.tokens.anyIt("meta.embedded.nim" in it.scopes)

    let unclosed = host.tokenizeLine("\"let", firstBody.completedRuleStack)
    check unclosed.ruleStack.depth == 3
    let restored =
      applyStateStackDiff(nil, diffStateStacksRefEq(nil, unclosed.completedRuleStack))
    check restored == unclosed.ruleStack
    let closing = host.tokenizeLine("```", restored)
    check closing.ruleStack.depth == 1

    let unknown = host.tokenizeLine("```unknown")
    check unknown.ruleStack.hasActiveScope("markup.fallback")

  test "validates runtime language registration and dynamic rule placement":
    let registry = newRegistry()
    expect MatterError:
      registry.registerLanguage("", "source.missing")
    expect MatterError:
      registry.registerLanguage("missing", "source.missing")
    registry.addGrammar(
      parseRawGrammar(
        """{ "scopeName": "source.test", "patterns": [{
          "match": "x", "matterEmbeddedLanguage": "language"
        }] }""",
        "invalid-embedded.json",
      )
    )
    expect MatterError:
      discard registry.loadGrammar("source.test")

  test "opens a continuation at EOF after its parent consumed the synthetic LF":
    let tested = grammar(
      """{
      "scopeName":"source.test", "patterns":[{
        "begin":"x\\s*$", "end":"!", "name":"outer",
        "patterns":[{"begin":"\\G", "while":"^", "contentName":"inner",
          "patterns":[{"match":"\\w+", "name":"word"}]}]
      }]
    }"""
    )
    let opened = tested.tokenizeLine("x")
    check opened.completedRuleStack.hasActiveScope("inner")
    let continued = tested.tokenizeLine("hello", opened.completedRuleStack)
    check continued.tokens.anyIt("inner" in it.scopes and "word" in it.scopes)

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

  test "matches a mid-line G alternative beside a line anchor":
    let tested = grammar(
      """{
      "scopeName":"source.test", "patterns":[{
        "begin":"^>", "end":"$", "patterns":[
          {"match":"(^|\\G)y", "name":"anchored.word"}
        ]
      }]
    }"""
    )
    check tested.tokenizeLine(">y").tokens.anyIt("anchored.word" in it.scopes)

  test "preserves an enclosing while anchor when an inner while fails":
    let tested = grammar(
      """{
      "scopeName":"source.test", "patterns":[{
        "begin":"^>", "while":"^>", "name":"outer", "patterns":[
          {"begin":"\\Gx", "while":"\\Gx", "name":"inner"},
          {"match":"\\Gy", "name":"after.inner"}
        ]
      }]
    }"""
    )
    let first = tested.tokenizeLine(">x")
    check first.completedRuleStack.depth == 3
    let second = tested.tokenizeLine(">y", first.completedRuleStack)
    check second.tokens[^1].scopes == @["source.test", "outer", "after.inner"]
    check second.completedRuleStack.depth == 2
    check tested.tokenizeLine("plain", second.completedRuleStack).completedRuleStack.depth ==
      1

  test "does not continue an empty-line while after the synthetic newline":
    let tested = grammar(
      """{
      "scopeName":"source.test", "patterns":[{
        "begin":"^start$", "while":"^$", "name":"blank.continuation"
      }]
    }"""
    )
    let first = tested.tokenizeLine("start")
    let second = tested.tokenizeLine("x", first.completedRuleStack)
    check second.tokens[0].scopes == @["source.test"]
    check second.completedRuleStack.depth == 1

  test "emits lookahead captures beyond the whole match without overlapping tokens":
    let tested = grammar(
      """{
      "scopeName":"source.test", "patterns":[{
        "match":"```(?=(css))", "captures":{"1":{"name":"fenced.language"}}
      }]
    }"""
    )
    let parsed = tested.tokenizeLine("```css")
    check parsed.tokens.mapIt((it.startIndex, it.endIndex, it.scopes[^1])) ==
      @[(0, 3, "source.test"), (3, 6, "fenced.language")]

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

  test "preserves line anchors when disabling G in a compiled end pattern":
    let tested = grammar(
      """{
      "scopeName":"source.test", "patterns":[{
        "begin":"<", "end":"^$|\\Gx", "name":"meta.open"
      }]
    }"""
    )
    let first = tested.tokenizeLine("<")
    let second = tested.tokenizeLine("y", first.completedRuleStack)
    check second.completedRuleStack.depth == 2
    check second.tokens[0].scopes == @["source.test", "meta.open"]

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

  test "distinguishes completed states whose anchors change next-line matching":
    let tested = grammar(
      """
      { "scopeName": "source.test", "patterns": [{
        "begin": ">|\\n", "while": "\\Gx", "name": "meta.continued",
        "patterns": [{ "match": "y", "name": "keyword.afterWhile" }]
      }] }
    """
    )
    let ordinaryBegin = tokenizeLine(tested, ">")
    let eolBegin = tokenizeLine(tested, "")
    check ordinaryBegin.ruleStack != eolBegin.ruleStack

    let ordinaryNext = tokenizeLine(tested, "xy", ordinaryBegin.ruleStack)
    let eolNext = tokenizeLine(tested, "xy", eolBegin.ruleStack)
    check not ordinaryNext.tokens.anyIt("keyword.afterWhile" in it.scopes)
    check eolNext.tokens.anyIt("keyword.afterWhile" in it.scopes)

  test "exposes active scopes without exposing mutable stack storage":
    let tested = grammar(
      """
      { "scopeName": "source.test", "patterns": [{
        "begin": "```", "end": "```", "name": "markup.fenced_code.block.markdown"
      }] }
    """
    )
    let first = tokenizeLine(tested, "```")
    let scopes = first.ruleStack.activeScopes
    check scopes == @["source.test", "markup.fenced_code.block.markdown"]
    check first.ruleStack.hasActiveScope("markup.fenced_code")
    check not first.ruleStack.hasActiveScope("markup.fenced_codeX")
    check not first.ruleStack.hasActiveScope("markup.quote")
    check not cast[StateStack](nil).hasActiveScope("markup.fenced_code")
    var changed = scopes
    changed[^1] = "changed.scope"
    check first.ruleStack.hasActiveScope("markup.fenced_code")

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
    expect MatterError:
      discard result.completedRuleStack
    let binary = tokenizeLine2(tested, "x".repeat(100_000), timeLimitMs = 1)
    check binary.stoppedEarly
    expect MatterError:
      discard binary.completedRuleStack

    let complete = tokenizeLine(tested, "x")
    check complete.completedRuleStack == complete.ruleStack
    let completeBinary = tokenizeLine2(tested, "x")
    check completeBinary.completedRuleStack == completeBinary.ruleStack

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
