## Ports of vscode-textmate's suite1/whileTests.json cases 1--9.
## Source: microsoft/vscode-textmate@fbe49961ab8077e587fdf5282019655ae69e5f9e
## License: MIT (see the upstream repository's LICENSE.md).
##
## The fixture is copied from suite1/fixtures/whileLang.plist at that commit.
## `staticRead` embeds it, so this suite neither reads `deps/` at runtime nor
## needs network access.

import std/[assertions, unittest]

import matter/[engine, rawgrammar]

const whileLangFixture = staticRead("fixtures/vscode-textmate/while/whileLang.plist")

type ExpectedToken = object
  value: string
  scopes: seq[string]

proc expected(value: string, scopes: openArray[string]): ExpectedToken =
  ExpectedToken(value: value, scopes: @scopes)

proc whileGrammar(): Grammar =
  let registry = newRegistry()
  registry.addGrammar(parseRawGrammar(whileLangFixture, "whileLang.plist"))
  registry.loadGrammar("text.whileLang")

proc tokenizeAndAssert(
    grammar: Grammar,
    line: string,
    expectedTokens: openArray[ExpectedToken],
    previousState: StateStack = nil,
): StateStack =
  let result = grammar.tokenizeLine(line, previousState)
  doAssert result.tokens.len == expectedTokens.len,
    "token count for line " & repr(line) & ": expected " & $expectedTokens.len & ", got " &
      $result.tokens.len
  for index in 0 ..< expectedTokens.len:
    let token = result.tokens[index]
    let expected = expectedTokens[index]
    doAssert line[token.startIndex ..< token.endIndex] == expected.value,
      "token text at index " & $index & " for line " & repr(line)
    doAssert token.scopes == expected.scopes,
      "scope path at token index " & $index & " for line " & repr(line)
  result.ruleStack

suite "vscode-textmate whileTests.json compatibility":
  test "case 1: While should match begin and stop on next line if while condition fails":
    let grammar = whileGrammar()
    let state = grammar.tokenizeAndAssert(
      "A x",
      [
        expected("A", ["text.whileLang", "alist"]),
        expected(" ", ["text.whileLang", "alist"]),
        expected("x", ["text.whileLang", "alist", "letter"]),
      ],
    )
    discard grammar.tokenizeAndAssert("c", [expected("c", ["text.whileLang"])], state)

  test "case 2: While should match multiple lines while condition holds":
    let grammar = whileGrammar()
    let first = grammar.tokenizeAndAssert(
      "A x",
      [
        expected("A", ["text.whileLang", "alist"]),
        expected(" ", ["text.whileLang", "alist"]),
        expected("x", ["text.whileLang", "alist", "letter"]),
      ],
    )
    let second = grammar.tokenizeAndAssert(
      "ax x",
      [
        expected("a", ["text.whileLang", "alist"]),
        expected("x", ["text.whileLang", "alist", "letter"]),
        expected(" ", ["text.whileLang", "alist"]),
        expected("x", ["text.whileLang", "alist", "letter"]),
      ],
      first,
    )
    discard grammar.tokenizeAndAssert("c", [expected("c", ["text.whileLang"])], second)

  test "case 3: While condition can match anywhere in line":
    let grammar = whileGrammar()
    let state = grammar.tokenizeAndAssert(
      "A x",
      [
        expected("A", ["text.whileLang", "alist"]),
        expected(" ", ["text.whileLang", "alist"]),
        expected("x", ["text.whileLang", "alist", "letter"]),
      ],
    )
    discard grammar.tokenizeAndAssert(
      "xax",
      [
        expected("x", ["text.whileLang", "alist"]),
        expected("a", ["text.whileLang", "alist"]),
        expected("x", ["text.whileLang", "alist", "letter"]),
      ],
      state,
    )

  test "case 4: Begin of while should consume entire rest of line.":
    let grammar = whileGrammar()
    discard grammar.tokenizeAndAssert(
      "A x B 1",
      [
        expected("A", ["text.whileLang", "alist"]),
        expected(" ", ["text.whileLang", "alist"]),
        expected("x", ["text.whileLang", "alist", "letter"]),
        expected(" ", ["text.whileLang", "alist"]),
        expected("B", ["text.whileLang", "alist", "blist"]),
        expected(" ", ["text.whileLang", "alist", "blist"]),
        expected("1", ["text.whileLang", "alist", "blist", "number"]),
      ],
    )

  test "case 5: Nested whiles should match using only inner most while on a mached line":
    let grammar = whileGrammar()
    let state = grammar.tokenizeAndAssert(
      "AB",
      [
        expected("A", ["text.whileLang", "alist"]),
        expected("B", ["text.whileLang", "alist", "blist"]),
      ],
    )
    discard grammar.tokenizeAndAssert(
      "abx1",
      [
        expected("a", ["text.whileLang", "alist"]),
        expected("b", ["text.whileLang", "alist", "blist", "bstart"]),
        expected("x", ["text.whileLang", "alist", "blist"]),
        expected("1", ["text.whileLang", "alist", "blist", "number"]),
      ],
      state,
    )

  test "case 6: Nested whiles should check line for outer most while to inner most while":
    let grammar = whileGrammar()
    let state = grammar.tokenizeAndAssert(
      "AB",
      [
        expected("A", ["text.whileLang", "alist"]),
        expected("B", ["text.whileLang", "alist", "blist"]),
      ],
    )
    discard grammar.tokenizeAndAssert("b1", [expected("b1", ["text.whileLang"])], state)

  test "case 7: Nested whiles should move line ahead before checking other conditions":
    let grammar = whileGrammar()
    let state = grammar.tokenizeAndAssert(
      "AB",
      [
        expected("A", ["text.whileLang", "alist"]),
        expected("B", ["text.whileLang", "alist", "blist"]),
      ],
    )
    discard grammar.tokenizeAndAssert(
      "bax",
      [
        expected("b", ["text.whileLang", "alist"]),
        expected("a", ["text.whileLang", "alist"]),
        expected("x", ["text.whileLang", "alist", "letter"]),
      ],
      state,
    )

  test "case 8: Nested whiles should check line for outer most while to inner most while":
    let grammar = whileGrammar()
    let state = grammar.tokenizeAndAssert(
      "AB",
      [
        expected("A", ["text.whileLang", "alist"]),
        expected("B", ["text.whileLang", "alist", "blist"]),
      ],
    )
    discard grammar.tokenizeAndAssert("b1", [expected("b1", ["text.whileLang"])], state)

  test "case 9: Should Correctly handle anchor in while rule":
    let grammar = whileGrammar()
    let state = grammar.tokenizeAndAssert(
      "BB",
      [
        expected("B", ["text.whileLang", "blist"]),
        expected("B", ["text.whileLang", "blist", "blist"]),
      ],
    )
    discard grammar.tokenizeAndAssert(
      "b b",
      [
        expected("b", ["text.whileLang", "blist", "bstart"]),
        expected(" b", ["text.whileLang", "blist"]),
      ],
      state,
    )
