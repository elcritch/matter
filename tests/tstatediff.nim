import std/unittest

import matter/[engine, rawgrammar]

proc grammar(source: string): Grammar =
  let registry = newRegistry()
  registry.addGrammar(parseRawGrammar(source, "state-diff.tmLanguage.json"))
  registry.loadGrammar("source.state")

suite "state stack diffs":
  test "no op and nil diffs preserve physical stacks":
    let tested = grammar(
      """
      { "scopeName": "source.state", "patterns": [] }
    """
    )
    let root = tokenizeLine(tested, "").ruleStack
    let noOp = diffStateStacksRefEq(root, root)
    check noOp.pops == 0
    check noOp.newFrames.len == 0
    check cast[pointer](applyStateStackDiff(root, noOp)) == cast[pointer](root)

    let fromNil = diffStateStacksRefEq(nil, root)
    check fromNil.pops == 0
    check fromNil.newFrames.len == 1
    check applyStateStackDiff(nil, fromNil) == root

    let toNil = diffStateStacksRefEq(root, nil)
    check toNil.pops == 1
    check applyStateStackDiff(root, toNil).isNil

  test "full suffix pushes and pops resume tokenization":
    let tested = grammar(
      """
      { "scopeName": "source.state", "patterns": [{
        "begin": "\\[", "end": "\\]", "name": "meta.square"
      }] }
    """
    )
    let root = tokenizeLine(tested, "").ruleStack
    let pushed = tokenizeLine(tested, "[", root).ruleStack
    let pushDiff = diffStateStacksRefEq(root, pushed)
    check pushDiff.pops == root.depth
    check pushDiff.newFrames.len == pushed.depth
    let restored = applyStateStackDiff(root, pushDiff)
    check restored == pushed
    let closed = tokenizeLine(tested, "]", restored)
    check closed.ruleStack.depth == 1

    let popDiff = diffStateStacksRefEq(pushed, root)
    check popDiff.pops == pushed.depth
    check popDiff.newFrames.len == root.depth
    check applyStateStackDiff(pushed, popDiff) == root

  test "divergent branches remain transportable after cross-line normalization":
    let tested = grammar(
      """
      { "scopeName": "source.state", "patterns": [
        { "begin": "\\[", "end": "\\]", "name": "meta.square" },
        { "begin": "\\{", "end": "\\}", "name": "meta.curly" }
      ] }
    """
    )
    let root = tokenizeLine(tested, "").ruleStack
    let square = tokenizeLine(tested, "[", root).ruleStack
    let curly = tokenizeLine(tested, "{", root).ruleStack
    let diff = diffStateStacksRefEq(square, curly)
    check diff.pops == square.depth
    check diff.newFrames.len == curly.depth
    check applyStateStackDiff(square, diff) == curly

  test "equivalent but distinct stacks do not share by structural equality":
    let tested = grammar(
      """
      { "scopeName": "source.state", "patterns": [{
        "begin": "<", "end": ">", "name": "meta.tag"
      }] }
    """
    )
    let first = tokenizeLine(tested, "<").ruleStack
    let second = tokenizeLine(tested, "<").ruleStack
    check first == second
    check cast[pointer](first) != cast[pointer](second)
    let diff = diffStateStacksRefEq(first, second)
    check diff.pops == first.depth
    check diff.newFrames.len == second.depth
    check applyStateStackDiff(first, diff) == second

  test "dynamic end and while snapshots continue across lines":
    let ended = grammar(
      """
      { "scopeName": "source.state", "patterns": [{
        "begin": "<(\\w+)>", "end": "</\\1>", "name": "meta.$1"
      }] }
    """
    )
    let root = tokenizeLine(ended, "").ruleStack
    let opened = tokenizeLine(ended, "<box>", root).ruleStack
    let copied = applyStateStackDiff(root, diffStateStacksRefEq(root, opened))
    let expectedEnd = tokenizeLine(ended, "</box>", opened)
    let copiedEnd = tokenizeLine(ended, "</box>", copied)
    check copiedEnd.tokens == expectedEnd.tokens
    check copiedEnd.ruleStack == expectedEnd.ruleStack

    let whileGrammar = grammar(
      """
      { "scopeName": "source.state", "patterns": [{
        "begin": "^>(\\w+)\\n", "while": "\\G>\\1", "name": "meta.quote"
      }] }
    """
    )
    let whileRoot = tokenizeLine(whileGrammar, "").ruleStack
    let whileState = tokenizeLine(whileGrammar, ">a", whileRoot).ruleStack
    let copiedWhile =
      applyStateStackDiff(whileRoot, diffStateStacksRefEq(whileRoot, whileState))
    let expectedWhile = tokenizeLine(whileGrammar, ">a", whileState)
    let copiedWhileResult = tokenizeLine(whileGrammar, ">a", copiedWhile)
    check copiedWhileResult.tokens == expectedWhile.tokens
    check copiedWhileResult.ruleStack == expectedWhile.ruleStack

  test "cross-line child close resets its parent zero width enter position":
    let tested = grammar(
      """
      { "scopeName": "source.state", "patterns": [{
        "begin": "\\(", "end": "(?=\\n)", "applyEndPatternLast": true, "name": "meta.parent",
        "patterns": [{ "begin": "(?<=\\()(?=\\n)", "end": "\\]", "name": "meta.child" }]
      }] }
    """
    )
    let first = tokenizeLine(tested, "a(")
    check first.ruleStack.depth == 3
    let second = tokenizeLine(tested, "]", first.ruleStack)
    check second.ruleStack.depth == 1

  test "invalid diffs raise MatterError":
    let tested = grammar(
      """
      { "scopeName": "source.state", "patterns": [] }
    """
    )
    let root = tokenizeLine(tested, "").ruleStack
    expect MatterError:
      discard applyStateStackDiff(root, StackDiff(pops: -1))
    expect MatterError:
      discard applyStateStackDiff(nil, StackDiff(pops: 1))
    expect MatterError:
      discard
        applyStateStackDiff(root, StackDiff(newFrames: @[default(StateStackFrame)]))
