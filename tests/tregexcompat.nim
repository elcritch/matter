import std/[unittest, sequtils, strutils]

import pkg/reni

import matter/[engine, rawgrammar, regexcompat]

suite "TextMate capture mode":
  test "keeps ordinary and named captures in source order":
    let matched = search("abc", re(textMateRegexSource("(a)(?<middle>b)(c)")))
    require matched.found
    check matched.groupCount == 3
    for index in 1 .. 3:
      check matched.captureSpan(index) == span(index - 1, index)

  test "preserves numeric named and relative references":
    for pattern in [
      r"(a)(?<middle>b)\1\k<middle>", r"(a)(?<middle>b)\k<-2>\k<-1>",
      r"(a)(?<middle>b)\g<1>\g<2>", r"(a)(?<middle>b)(?(1)a|x)b",
    ]:
      checkpoint(pattern)
      let matched = search("abab", re(textMateRegexSource(pattern)))
      require matched.found
      check matched.matchSpan == span(0, 4)

  test "keeps duplicate named groups and avoids private name collisions":
    let source = r"(?:(?<same>a)|(?<same>b))(c)\k<same>"
    for text in ["aca", "bcb"]:
      let matched = search(text, re(textMateRegexSource(source)))
      require matched.found
      check matched.groupCount == 3
      check matched.captureSpan(3) == span(1, 2)
    let collision = search("ab", re(textMateRegexSource("(?<matterCapture2>a)(b)")))
    require collision.found
    check collision.groupCount == 2

  test "ignores escaped delimiters classes and extended comments":
    for (pattern, text, captures) in [
      (r"\((?<name>a)[()]([[:alpha:]])\)", "(a(b)", 2),
      ("(?x) # (ignored)\n(?<name>a)(b)(?# (ignored)", "ab", 2),
      ("(?x:(?<name>a) # (ignored)\n)(?-x:(#))(b)", "a#b", 3),
      ("(?<name>a)[]()]([b])", "a)b", 2),
    ]:
      checkpoint(pattern)
      let matched = search(text, re(textMateRegexSource(pattern)))
      require matched.found
      check matched.groupCount == captures

  test "leaves quoted regex text and commented anchors intact":
    let pattern = r"(?<name>a)\Q(^$\G)\E(b)"
    let matched = search(r"a(^$\G)b", re(textMateRegexSource(pattern, false, false)))
    require matched.found
    check matched.groupCount == 2
    check regexAnchors(pattern) == {}
    check regexAnchors("(?x)# \\G\n[\\A](?# \\K)\\G") == {'G'}

  test "line anchors exclude the synthetic terminal position":
    for pattern in ["^", "$"]:
      let regex = re(textMateRegexSource(pattern))
      check search("x\n", regex).found
      check not search("x\n", regex, start = 2).found

  test "rejects ambiguous and overflowing numeric references":
    for pattern in [r"(?<same>a)(?<same>b)\1", "(?<x>a)\\k<" & "9".repeat(100) & ">"]:
      let registry = newRegistry()
      # The public compiler must wrap adapter failures as MatterError.
      registry.addGrammar(
        RawGrammar(scopeName: "source.test", patterns: @[RawRule(match: pattern)])
      )
      expect MatterError:
        discard registry.loadGrammar("source.test")

  test "exports numbered capture scopes through the public tokenizer":
    let registry = newRegistry()
    registry.addGrammar(
      parseRawGrammar(
        """{
      "scopeName":"source.test", "patterns":[{
        "match":"(a)(?<named>b)(c)", "captures":{
          "1":{"name":"first"}, "2":{"name":"second"}, "3":{"name":"third"}
        }
      }]
    }""",
        "mixed.json",
      )
    )
    let parsed = registry.loadGrammar("source.test").tokenizeLine("abc")
    check parsed.tokens.mapIt(it.scopes[^1]) == @["first", "second", "third"]
