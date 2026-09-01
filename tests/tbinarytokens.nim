import std/[strutils, unittest]

import matter/[engine, metadata, rawgrammar, theme]

proc compileGrammar(source: string, configuration = GrammarConfiguration()): Grammar =
  let registry = newRegistry()
  registry.addGrammar(parseRawGrammar(source, "binary.tmLanguage.json"))
  registry.loadGrammar("source.binary", configuration)

proc scopesAt(tokens: openArray[Token], offset: int): seq[string] =
  for token in tokens:
    if token.startIndex <= offset and offset < token.endIndex:
      return token.scopes

proc metadataAt(tokens: openArray[uint32], offset: int): EncodedTokenAttributes =
  for index in countup(0, tokens.high - 1, 2):
    if int(tokens[index]) > offset:
      break
    result = tokens[index + 1]

suite "themed binary tokens":
  test "registry defaults are defensive and loaded grammars observe replacement":
    let registry = newRegistry()
    check registry.colorMap() == @["", "#000000", "#FFFFFF"]
    var colors = registry.colorMap()
    colors[1] = "#BROKEN"
    check registry.colorMap()[1] == "#000000"
    registry.addGrammar(
      parseRawGrammar(
        """{ "scopeName": "source.binary", "patterns": [
          { "match": "x", "name": "constant.colored" }
        ] }""",
        "replacement.tmLanguage.json",
      )
    )
    let grammar =
      registry.loadGrammar("source.binary", GrammarConfiguration(initialLanguageId: 5))
    let before = tokenizeLine2(grammar, "x")
    registry.setTheme(
      parseRawTheme(
        """{ "settings": [
          { "settings": { "foreground": "#000000", "background": "#FFFFFF" } },
          { "scope": "constant.colored", "settings": { "foreground": "#FF0000" } }
        ] }""",
        "replacement.tmTheme.json",
      )
    )
    let after = tokenizeLine2(grammar, "x")
    check before.tokens != after.tokens
    check after.tokens[1].getLanguageId() == 5
    check registry.colorMap()[3] == "#FF0000"
    registry.setTheme(newTheme(RawTheme()))
    check tokenizeLine2(grammar, "x").tokens == before.tokens

  test "embedded languages select per scope and semantic words inherit or reset":
    let grammar = compileGrammar(
      """{ "scopeName": "source.binary", "patterns": [
        { "begin": "<", "end": ">", "name": "meta.outer.really.long",
          "patterns": [{ "match": "x", "name": "source.js.comment.deep" }] },
        { "begin": "\\[", "end": "\\]", "name": "string.quoted",
          "patterns": [{ "match": "s", "name": "entity.deep" }] },
        { "match": "e", "name": "meta.embedded.template" }
      ] }""",
      GrammarConfiguration(
        initialLanguageId: 2,
        embeddedLanguages:
          @[
            EmbeddedLanguage(scopeName: "meta.outer.really.long", languageId: 3),
            EmbeddedLanguage(scopeName: "source.js", languageId: 7),
          ],
      ),
    )
    let result = tokenizeLine2(grammar, "<x>[s]e")
    check result.tokens.metadataAt(0).getLanguageId() == 3
    check result.tokens.metadataAt(1).getLanguageId() == 7
    check result.tokens.metadataAt(1).getTokenType() == StandardTokenType.Comment
    check result.tokens.metadataAt(4).getTokenType() == StandardTokenType.String
    check result.tokens.metadataAt(6).getTokenType() == StandardTokenType.Other

  test "ordered token overrides and bracket selectors control packed metadata":
    let grammar = compileGrammar(
      """{ "scopeName": "source.binary", "patterns": [
        { "match": "\\(", "name": "punctuation.open" },
        { "match": "\\)", "name": "punctuation.close" },
        { "match": "s", "name": "string.quoted" }
      ] }""",
      GrammarConfiguration(
        tokenTypes:
          @[
            TokenTypeOverride(selector: "string", tokenType: StandardTokenType.Comment),
            TokenTypeOverride(
              selector: "string.quoted", tokenType: StandardTokenType.RegEx
            ),
          ],
        balancedBracketSelectors: @["*"],
        unbalancedBracketSelectors: @["punctuation.close"],
      ),
    )
    let result = tokenizeLine2(grammar, "()s")
    check result.tokens[1].containsBalancedBrackets()
    check not result.tokens[3].containsBalancedBrackets()
    check result.tokens[^1].getTokenType() == StandardTokenType.RegEx

  test "font spans coalesce and metadata only coalesces non RTL lines":
    let registry = newRegistry()
    registry.setTheme(
      parseRawTheme(
        """{ "settings": [{ "settings": {
          "foreground": "#000000", "background": "#FFFFFF",
          "fontFamily": "Mono", "fontSize": 1.2, "lineHeight": 3
        }}] }""",
        "fonts.tmTheme.json",
      )
    )
    registry.addGrammar(
      parseRawGrammar(
        """{ "scopeName": "source.binary", "patterns": [
          { "match": "a", "name": "entity.a" },
          { "match": "b", "name": "entity.b" }
        ] }""",
        "fonts.tmLanguage.json",
      )
    )
    let grammar = registry.loadGrammar("source.binary")
    let ltr = tokenizeLine2(grammar, "ab")
    check ltr.tokens.len == 2
    check ltr.fonts ==
      @[
        FontInfo(
          startIndex: 0,
          endIndex: 2,
          fontFamily: "Mono",
          fontSizeMultiplier: 1.2,
          lineHeightMultiplier: 3,
        )
      ]
    let rtl = tokenizeLine2(grammar, "aאb")
    check rtl.tokens.len == 6
    check rtl.tokens[0] == 0
    check rtl.tokens[2] == 1
    check rtl.tokens[4] == 3
    let arabicDigit = tokenizeLine2(grammar, "a١b")
    check arabicDigit.tokens.len == 2
    let nonRtlBoundary = tokenizeLine2(grammar, "a\u07EBb")
    check nonRtlBoundary.tokens.len == 2
    let rtlBoundary = tokenizeLine2(grammar, "a\u0860b")
    check rtlBoundary.tokens.len == 6

  test "empty multiline time limited and exact vectors preserve state":
    let exact = compileGrammar(
      """{ "scopeName": "source.binary", "patterns": [
        { "match": "c", "name": "comment.line" }
      ] }""",
      GrammarConfiguration(
        initialLanguageId: 9, balancedBracketSelectors: @["comment.line"]
      ),
    )
    let registry = newRegistry()
    registry.setTheme(
      parseRawTheme(
        """{ "settings": [
          { "settings": { "foreground": "#000000", "background": "#FFFFFF" } },
          { "scope": "comment.line", "settings": {
            "foreground": "#FF0000", "fontStyle": "italic" } }
        ] }""",
        "exact.tmTheme.json",
      )
    )
    registry.addGrammar(
      parseRawGrammar(
        """{ "scopeName": "source.binary", "patterns": [
          { "match": "c", "name": "comment.line" },
          { "begin": "<", "end": ">", "name": "meta.line" },
          { "match": "x", "name": "constant.x" }
        ] }""",
        "exact.tmLanguage.json",
      )
    )
    let configured = registry.loadGrammar(
      "source.binary",
      GrammarConfiguration(
        initialLanguageId: 9, balancedBracketSelectors: @["comment.line"]
      ),
    )
    check tokenizeLine2(exact, "").tokens.len == 2
    check tokenizeLine2(configured, "c").tokens == @[0'u32, 0x02018d09'u32]
    let opened = tokenizeLine2(configured, "<")
    let closed = tokenizeLine2(configured, ">", opened.ruleStack)
    check opened.ruleStack.depth == 2
    check closed.ruleStack.depth == 1
    let limited = tokenizeLine2(configured, "x".repeat(100_000), timeLimitMs = 1)
    check limited.stoppedEarly
    check limited.ruleStack != nil
