import std/[json, os, sequtils, sets, strutils, unittest]

import pkg/zippy/crc

import matter
import matter/grammarloader

const
  root = currentSourcePath.parentDir.parentDir
  htmlSource = staticRead("fixtures/html/features.html")
  cssSource = staticRead("fixtures/css/css.tmLanguage.json")
  coverageSource = staticRead("fixtures/html/coverage.html")
  merendaSource = staticRead("fixtures/html/merenda.html")
  boundarySource = staticRead("fixtures/html/host-boundaries.html")

proc bundledHtml(registry: Registry, scope = "text.html.derivative"): Grammar =
  let loaded = registry.loadGrammarPackage(zipResourceSource(root), scope)
  doAssert loaded.unresolvedIncludes.len == 0
  registry.loadGrammar(scope)

proc metadataAt(parsed: TokenizeLineResult2, offset: int): EncodedTokenAttributes =
  for i in countup(0, parsed.tokens.high - 1, 2):
    if parsed.tokens[i].int <= offset:
      result = parsed.tokens[i + 1]

suite "HTML TextMate grammar":
  test "exports both HTML catalog entries from the root module":
    check htmlGrammar.scopeName == "text.html.derivative"
    check htmlBasicGrammar.scopeName == "text.html.basic"
    check vscodeHtmlPackage.name == "html"

  test "matches complete reference snapshots for both bundled HTML roots":
    var scopes: HashSet[string]
    for (scope, source, expected) in [
      ("text.html.derivative", coverageSource, 0xE4417669'u32),
      ("text.html.basic", coverageSource, 0x37A3741D'u32),
      ("text.html.derivative", merendaSource, 0xCAC2C77A'u32),
    ]:
      let grammar = bundledHtml(newRegistry(), scope)
      for limit in [0, 10_000]:
        var
          state: StateStack
          snapshot: string
        let lines = source.splitLines()
        for index, line in lines:
          checkpoint(scope & " line " & $(index + 1) & " budget " & $limit)
          let parsed = grammar.tokenizeLine(line, state, limit)
          require not parsed.stoppedEarly
          state = parsed.completedRuleStack
          var finish = 0
          for token in parsed.tokens:
            check token.startIndex == finish
            check token.endIndex > token.startIndex
            check token.endIndex <= line.len
            finish = token.endIndex
            for name in token.scopes:
              scopes.incl(name)
          check finish == line.len
          snapshot.add($(%parsed.tokens) & "\n")
        check state.depth == 1
        check crc32(snapshot) == expected
    for name in [
      "entity.name.tag.html", "entity.other.attribute-name.html",
      "meta.tag.structure.section.start.html", "meta.tag.inline.strong.start.html",
      "meta.tag.object.img.void.html", "meta.tag.metadata.doctype.html",
      "meta.tag.metadata.processing.xml.html", "meta.tag.metadata.cdata.html",
      "meta.tag.custom.start.html", "meta.tag.other.unrecognized.html.derivative",
      "meta.attribute.data-x.data-state.html",
      "meta.attribute.event-handler.click.html", "string.quoted.double.html",
      "string.quoted.single.html", "string.unquoted.html",
      "constant.character.entity.named.amp.html",
      "constant.character.entity.numeric.decimal.html",
      "constant.character.entity.numeric.hexadecimal.html", "comment.block.html",
      "punctuation.definition.tag.begin.html", "punctuation.definition.tag.end.html",
      "punctuation.separator.key-value.html", "punctuation.definition.entity.html",
      "invalid.deprecated.html", "invalid.deprecated.entity.other.attribute-name.html",
      "invalid.illegal.bad-angle-bracket.html", "invalid.illegal.newline.js",
      "meta.element.object.svg.path.html", "meta.element.inline.math.mi.html",
      "source.css", "support.type.property-name.css", "source.js", "storage.type.js",
    ]:
      checkpoint(name)
      check name in scopes

  test "HTML classes drive theme colors and every exported font style":
    let registry = newRegistry()
    registry.setTheme(
      parseRawTheme(
        """{"settings":[
      {"scope":"entity.name.tag.html","settings":{"foreground":"#AA0000","fontStyle":"bold"}},
      {"scope":"entity.other.attribute-name.html","settings":{"foreground":"#00AA00","fontStyle":"italic"}},
      {"scope":"string.quoted.double.html","settings":{"foreground":"#0000AA","fontStyle":"underline"}},
      {"scope":"constant.character.entity","settings":{"foreground":"#AAAA00","fontStyle":"strikethrough"}}
    ]}""",
        "html-theme.json",
      )
    )
    let grammar = bundledHtml(registry)
    let source = "<a class=\"panel\" href=\"/\">&amp;</a>"
    let parsed = grammar.tokenizeLine2(source)
    for (offset, color, style) in [
      (1, "#AA0000", fontStyleBold),
      (source.find("class"), "#00AA00", fontStyleItalic),
      (source.find("panel"), "#0000AA", fontStyleUnderline),
      (source.find("&amp;"), "#AAAA00", fontStyleStrikethrough),
    ]:
      let metadata = parsed.metadataAt(offset)
      check metadata.getFontStyle.contains(style)
      check registry.colorMap()[metadata.getForeground.int] == color

  test "embedded language IDs and token types remain available to editors":
    let registry = newRegistry()
    discard bundledHtml(registry)
    let grammar = registry.loadGrammar(
      "text.html.derivative",
      GrammarConfiguration(
        initialLanguageId: 1,
        embeddedLanguages:
          @[
            EmbeddedLanguage(scopeName: "source.css", languageId: 2),
            EmbeddedLanguage(scopeName: "source.js", languageId: 3),
          ],
      ),
    )
    for (source, fragment, language, kind) in [
      ("<div title=\"text\">", "text", 1'u32, StandardTokenType.String),
      ("<!-- comment -->", "comment", 1'u32, StandardTokenType.Comment),
      ("<style>body { color: red; }</style>", "color", 2'u32, StandardTokenType.Other),
      ("<script>const x = 42;</script>", "42", 3'u32, StandardTokenType.Other),
      # The bundled JS grammar names regex literals string.regexp.js, so
      # TextMate's default binary token classification reports String.
      ("<script>const r = /abc/;</script>", "abc", 3'u32, StandardTokenType.String),
    ]:
      let metadata = grammar.tokenizeLine2(source).metadataAt(source.find(fragment))
      check metadata.getLanguageId == language
      check metadata.getTokenType == kind

    let overridden = registry.loadGrammar(
      "text.html.derivative",
      GrammarConfiguration(
        tokenTypes:
          @[
            TokenTypeOverride(
              selector: "string.regexp.js", tokenType: StandardTokenType.RegEx
            )
          ]
      ),
    )
    let regexLine = "<script>const r = /abc/;</script>"
    check overridden
    .tokenizeLine2(regexLine)
    .metadataAt(regexLine.find("abc")).getTokenType == StandardTokenType.RegEx

  test "preserves the reference's state for malformed script host boundaries":
    let grammar = bundledHtml(newRegistry())
    var
      state: StateStack
      snapshot: string
    let lines = boundarySource.splitLines()
    for line in lines:
      let parsed = grammar.tokenizeLine(line, state)
      require not parsed.stoppedEarly
      state = parsed.completedRuleStack
      snapshot.add($(%parsed.tokens) & "\n")
    check crc32(snapshot) == 0xDF5C509F'u32
    # The upstream HTML grammar leaves JS active after an unterminated
    # string at </script>. Keep this limitation explicit, not hidden in
    # the coverage fixture's subsequent scopes.
    check state.hasActiveScope("source.js")

  test "retokenized malformed handlers end at the HTML capture boundary":
    let grammar = bundledHtml(newRegistry())
    let source = "<button onclick=\"x = 'broken\" id=\"after\">After</button>"
    let parsed = grammar.tokenizeLine(source)
    check parsed.tokens.anyIt("invalid.illegal.newline.js" in it.scopes)
    let offset = source.find("id=")
    check parsed.tokens.anyIt(
      it.startIndex <= offset and offset < it.endIndex and
        "entity.other.attribute-name.html" in it.scopes and "source.js" notin it.scopes
    )
    check parsed.completedRuleStack.depth == 1

  test "saved state and empty-line scopes preserve embedded and attribute contexts":
    let grammar = bundledHtml(newRegistry())
    for (beginLine, closeLine, scope) in [
      ("<script>", "</script><div>clean</div>", "source.js"),
      ("<style>", "</style><div>clean</div>", "source.css"),
      ("<div title=\"open", "closed\"><span>clean</span>", "string.quoted.double.html"),
      ("<!-- open", "--><div>clean</div>", "comment.block.html"),
    ]:
      let initial = grammar.tokenizeLine(beginLine).completedRuleStack
      let empty = grammar.tokenizeLine("", initial).completedRuleStack
      check empty.hasActiveScope(scope)
      let restored = applyStateStackDiff(initial, diffStateStacksRefEq(initial, empty))
      check restored.activeScopes == empty.activeScopes
      let closed = grammar.tokenizeLine(closeLine, restored)
      let direct = grammar.tokenizeLine(closeLine, empty)
      check closed.tokens == direct.tokens
      check closed.completedRuleStack.depth == 1
      check initial.hasActiveScope(scope)

  test "loads embedded CSS and JavaScript from the HTML package alone":
    let registry = newRegistry()
    let loaded =
      registry.loadGrammarPackage(zipResourceSource(root), "text.html.derivative")
    check "source.css" in loaded.loadedScopeNames
    check "source.js" in loaded.loadedScopeNames
    let grammar = registry.loadGrammar("text.html.derivative")
    let css = grammar.tokenizeLine("<style>body { color: red; }</style>")
    check css.tokens.anyIt("support.type.property-name.css" in it.scopes)
    let js = grammar.tokenizeLine("<script>const answer = 42;</script>")
    check js.tokens.anyIt("constant.numeric.decimal.js" in it.scopes)

  test "matches VS Code scopes and UTF-8 ranges including embedded CSS and JavaScript":
    let registry = newRegistry()
    registry.addGrammar(parseRawGrammar(cssSource, "css.tmLanguage.json"))
    discard registry.loadGrammarPackage(
      zipResourceSource(root), ["text.html.derivative", "source.js"]
    )
    let grammar = registry.loadGrammar("text.html.derivative")
    let lines = htmlSource.splitLines()
    var
      state: StateStack
      snapshot: string
    for index, line in lines:
      checkpoint("HTML fixture line " & $(index + 1))
      let parsed = grammar.tokenizeLine(line, state)
      check not parsed.stoppedEarly
      state = parsed.completedRuleStack
      snapshot.add($(%parsed.tokens) & "\n")
    check state.depth == 1
    # vscode-textmate 9.2.0 + vscode-oniguruma 2.0.1, with synthetic newlines
    # excluded and UTF-16 reference offsets converted to UTF-8 byte offsets.
    check crc32(snapshot) == 0x1DAE729B'u32
