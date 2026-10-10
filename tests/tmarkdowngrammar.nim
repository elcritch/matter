import std/[json, os, sets, strutils, unittest]

import pkg/zippy/crc

import matter
import matter/grammarloader

const
  root = currentSourcePath.parentDir.parentDir
  features = staticRead("fixtures/markdown/features.md")
  merenda = staticRead("fixtures/markdown/merenda.md")

proc markdownGrammar(registry: Registry): Grammar =
  let loaded =
    registry.loadGrammarPackage(zipResourceSource(root), "text.html.markdown")
  doAssert "source.css" in loaded.loadedScopeNames
  doAssert "source.js" in loaded.loadedScopeNames
  registry.loadGrammar("text.html.markdown")

suite "Markdown TextMate grammar":
  test "matches reference ranges and scopes for every Markdown feature":
    let grammar = markdownGrammar(newRegistry())
    var scopes: HashSet[string]
    for (source, expected) in [(features, 0x9CE9F590'u32), (merenda, 0x3C62BA15'u32)]:
      for limit in [0, 10_000]:
        var
          state: StateStack
          snapshot: string
        let lines = source.splitLines()
        for index, line in lines:
          checkpoint("Line " & $(index + 1) & ", budget " & $limit)
          let parsed = grammar.tokenizeLine(line, state, limit)
          require not parsed.stoppedEarly
          state = parsed.completedRuleStack
          for token in parsed.tokens:
            for scope in token.scopes:
              scopes.incl(scope)
          snapshot.add($(%parsed.tokens) & "\n")
        check not state.hasActiveScope("markup.fenced_code")
        check not state.hasActiveScope("meta.embedded.block.frontmatter")
        # vscode-textmate 9.2.0 + vscode-oniguruma 2.0.1, all bundled grammars.
        check crc32(snapshot) == expected
    for scope in [
      "markup.heading.markdown", "heading.1.markdown", "heading.2.markdown",
      "heading.3.markdown", "heading.4.markdown", "heading.5.markdown",
      "heading.6.markdown", "markup.heading.setext.1.markdown",
      "markup.heading.setext.2.markdown", "markup.bold.markdown",
      "markup.italic.markdown", "markup.strikethrough.markdown",
      "markup.inline.raw.string.markdown", "markup.raw.block.markdown",
      "markup.quote.markdown", "markup.list.numbered.markdown",
      "markup.list.unnumbered.markdown", "markup.table.markdown",
      "markup.underline.link.markdown", "markup.underline.link.image.markdown",
      "meta.link.inline.markdown", "meta.link.reference.markdown",
      "meta.link.email.lt-gt.markdown", "punctuation.definition.heading.markdown",
      "punctuation.definition.link.title.begin.markdown",
      "punctuation.definition.list.begin.markdown",
      "punctuation.definition.quote.begin.markdown",
      "punctuation.definition.end.frontmatter", "meta.separator.markdown",
      "markup.fenced_code.block.markdown", "fenced_code.block.language",
      "fenced_code.block.language.markdown", "meta.embedded.block.css",
      "meta.embedded.block.javascript",
    ]:
      checkpoint(scope)
      check scope in scopes

  test "Markdown scopes drive all four exported theme font styles":
    let registry = newRegistry()
    registry.setTheme(
      parseRawTheme(
        """{"settings":[
      {"scope":"markup.bold","settings":{"fontStyle":"bold"}},
      {"scope":"markup.italic","settings":{"fontStyle":"italic"}},
      {"scope":"markup.strikethrough","settings":{"fontStyle":"strikethrough"}},
      {"scope":"markup.underline.link","settings":{"fontStyle":"underline"}}
    ]}""",
        "markdown-theme.json",
      )
    )
    let grammar = markdownGrammar(registry)
    let source = "**bold** *italic* ~~strike~~ [link](target)"
    let parsed = grammar.tokenizeLine2(source)
    for (fragment, expected) in [
      ("bold", fontStyleBold),
      ("italic", fontStyleItalic),
      ("strike", fontStyleStrikethrough),
      ("target", fontStyleUnderline),
    ]:
      let offset = source.find(fragment)
      var found = false
      for index in countup(0, parsed.tokens.high - 1, 2):
        let finish =
          if index + 2 < parsed.tokens.len:
            parsed.tokens[index + 2].int
          else:
            source.len
        if parsed.tokens[index].int <= offset and offset < finish:
          check parsed.tokens[index + 1].getFontStyle.contains(expected)
          found = true
      check found
