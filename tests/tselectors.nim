import std/[assertions, unittest]

import matter/selectors

proc anyMatches(source: string, scopes: openArray[string]): bool =
  for selector in parseScopeSelectors(source):
    if selector.matches(scopes):
      return true
  false

suite "TextMate scope selectors":
  test "match alternatives and ordered conjunctions":
    doAssert anyMatches("bar, foo", ["foo"])
    doAssert anyMatches("bar, foo", ["bar"])
    doAssert anyMatches("bar foo", ["bar", "foo"])
    doAssert not anyMatches("bar foo", ["foo", "bar"])
    doAssert not anyMatches("bar foo", ["bar"])

  test "match exclusions and grouped expressions":
    doAssert anyMatches("bar - foo", ["bar"])
    doAssert not anyMatches("bar - foo", ["foo", "bar"])
    doAssert anyMatches("foo bar - (yo man)", ["foo", "bar", "yo"])
    doAssert not anyMatches("foo bar - (yo man)", ["foo", "bar", "yo", "man"])
    doAssert not anyMatches("foo bar - (yo | man)", ["foo", "bar", "yo"])
    doAssert anyMatches("- - foo", ["foo"])

  test "match grouped alternatives":
    doAssert anyMatches("(foo | bar)", ["foo"])
    doAssert anyMatches("(foo, bar)", ["bar"])
    doAssert not anyMatches("(foo | bar)", ["baz"])
    doAssert anyMatches(
      "R:text.html - (comment.block, text.html source)", ["text.html", "bar"]
    )
    doAssert not anyMatches(
      "R:text.html - (comment.block, text.html source)", ["text.html", "bar", "source"]
    )

  test "match dotted scope prefixes at scope boundaries":
    doAssert anyMatches("source", ["source.nim"])
    doAssert anyMatches("meta.embedded", ["text.html", "meta.embedded.block"])
    doAssert not anyMatches("source.js", ["source.json"])
    doAssert not anyMatches("source", [""])

  test "retain priorities for top-level alternatives":
    let selectors =
      parseScopeSelectors("R:text.html - comment, L:source.js, text.plain")
    doAssert selectors.len == 3
    doAssert selectors[0].priority == spRight
    doAssert selectors[1].priority == spLeft
    doAssert selectors[2].priority == spDefault
    doAssert selectors[0].matches(["text.html"])
    doAssert selectors[1].matches(["source.js.embedded.html"])
    doAssert selectors[2].matches(["text.plain"])

  test "prioritized alternatives preserve TextMate selector behavior":
    doAssert anyMatches(
      "text.html.php - (meta.embedded | meta.tag), " &
        "L:text.html.php meta.tag, L:source.js.embedded.html",
      ["text.html.php", "bar", "source.js"],
    )
