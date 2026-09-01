## Matcher conformance vectors ported from vscode-textmate's
## src/tests/matcher.test.ts at fbe49961ab8077e587fdf5282019655ae69e5f9e.

import std/[assertions, unittest]

import matter/selectors

proc anyMatches(expression: string, scopes: openArray[string]): bool =
  for selector in parseScopeSelectors(expression):
    if selector.matches(scopes):
      return true
  false

suite "vscode-textmate matcher conformance":
  test "Matcher Test #0":
    doAssert anyMatches("foo", ["foo"])

  test "Matcher Test #1":
    doAssert not anyMatches("foo", ["bar"])

  test "Matcher Test #2":
    doAssert not anyMatches("- foo", ["foo"])

  test "Matcher Test #3":
    doAssert anyMatches("- foo", ["bar"])

  test "Matcher Test #4":
    doAssert not anyMatches("- - foo", ["bar"])

  test "Matcher Test #5":
    doAssert not anyMatches("bar foo", ["foo"])

  test "Matcher Test #6":
    doAssert not anyMatches("bar foo", ["bar"])

  test "Matcher Test #7":
    doAssert anyMatches("bar foo", ["bar", "foo"])

  test "Matcher Test #8":
    doAssert anyMatches("bar - foo", ["bar"])

  test "Matcher Test #9":
    doAssert not anyMatches("bar - foo", ["foo", "bar"])

  test "Matcher Test #10":
    doAssert not anyMatches("bar - foo", ["foo"])

  test "Matcher Test #11":
    doAssert anyMatches("bar, foo", ["foo"])

  test "Matcher Test #12":
    doAssert anyMatches("bar, foo", ["bar"])

  test "Matcher Test #13":
    doAssert anyMatches("bar, foo", ["bar", "foo"])

  test "Matcher Test #14":
    doAssert anyMatches("bar, -foo", ["bar", "foo"])

  test "Matcher Test #15":
    doAssert anyMatches("bar, -foo", ["yo"])

  test "Matcher Test #16":
    doAssert not anyMatches("bar, -foo", ["foo"])

  test "Matcher Test #17":
    doAssert anyMatches("(foo)", ["foo"])

  test "Matcher Test #18":
    doAssert anyMatches("(foo - bar)", ["foo"])

  test "Matcher Test #19":
    doAssert not anyMatches("(foo - bar)", ["foo", "bar"])

  test "Matcher Test #20":
    doAssert anyMatches("foo bar - (yo man)", ["foo", "bar"])

  test "Matcher Test #21":
    doAssert anyMatches("foo bar - (yo man)", ["foo", "bar", "yo"])

  test "Matcher Test #22":
    doAssert not anyMatches("foo bar - (yo man)", ["foo", "bar", "yo", "man"])

  test "Matcher Test #23":
    doAssert not anyMatches("foo bar - (yo | man)", ["foo", "bar", "yo", "man"])

  test "Matcher Test #24":
    doAssert not anyMatches("foo bar - (yo | man)", ["foo", "bar", "yo"])

  test "Matcher Test #25":
    doAssert not anyMatches(
      "R:text.html - (comment.block, text.html source)", ["text.html", "bar", "source"]
    )

  test "Matcher Test #26":
    doAssert anyMatches(
      "text.html.php - (meta.embedded | meta.tag), " &
        "L:text.html.php meta.tag, L:source.js.embedded.html",
      ["text.html.php", "bar", "source.js"],
    )
