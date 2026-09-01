import std/unittest

import matter/[engine, metadata, rawgrammar, theme]

proc newRegistryWithGrammar(source: string): Registry =
  result = newRegistry()
  result.addGrammar(parseRawGrammar(source, "binary.tmLanguage.json"))

proc metadataAt(
    tokenResult: TokenizeLineResult2, byteIndex, lineLength: int
): EncodedTokenAttributes =
  var index = 0
  while index < tokenResult.tokens.len:
    let start = int(tokenResult.tokens[index])
    let stop =
      if index + 2 < tokenResult.tokens.len:
        int(tokenResult.tokens[index + 2])
      else:
        lineLength
    if start <= byteIndex and byteIndex < stop:
      return tokenResult.tokens[index + 1]
    index += 2
  raise newException(ValueError, "no binary token at requested byte offset")

proc foregroundColor(registry: Registry, metadata: EncodedTokenAttributes): string =
  registry.colorMap()[int(metadata.getForeground())]

suite "binary token compatibility":
  test "scope styles accumulate and loaded grammars observe theme replacement":
    let registry = newRegistryWithGrammar(
      """
      { "scopeName": "source.binary", "patterns": [{
        "begin": "\\[", "end": "\\]", "name": "meta.outer",
        "patterns": [{ "match": "x", "name": "entity.inner" }]
      }] }
    """
    )
    registry.setTheme(
      parseRawTheme(
        """
      { "settings": [
        { "settings": { "foreground": "#000000", "background": "#FFFFFF" } },
        { "scope": "meta.outer", "settings": {
          "foreground": "#112233", "fontStyle": "italic"
        } },
        { "scope": "meta.outer entity.inner", "settings": { "fontStyle": "bold" } }
      ] }
    """,
        "first-theme.json",
      )
    )
    let grammar = registry.loadGrammar("source.binary", GrammarConfiguration())
    let first = grammar.tokenizeLine2("[x]")
    let firstInner = first.metadataAt(1, 3)
    check registry.foregroundColor(firstInner) == "#112233"
    check firstInner.getFontStyle().fontStyleValue == fontStyleBold.fontStyleValue

    registry.setTheme(
      parseRawTheme(
        """
      { "settings": [
        { "settings": { "foreground": "#000000", "background": "#FFFFFF" } },
        { "scope": "meta.outer", "settings": {
          "foreground": "#AABBCC", "fontStyle": "underline"
        } },
        { "scope": "meta.outer entity.inner", "settings": {
          "fontStyle": "strikethrough"
        } }
      ] }
    """,
        "second-theme.json",
      )
    )
    let secondInner = grammar.tokenizeLine2("[x]").metadataAt(1, 3)
    check registry.foregroundColor(secondInner) == "#AABBCC"
    check secondInner.getFontStyle().fontStyleValue ==
      fontStyleStrikethrough.fontStyleValue

  test "longest embedded scope and last token-type override win":
    let registry = newRegistryWithGrammar(
      """
      { "scopeName": "source.binary", "patterns": [{
        "begin": "\\[", "end": "\\]", "name": "meta.embedded.deep",
        "patterns": [{ "match": "x", "name": "scope.override" }]
      }] }
    """
    )
    let grammar = registry.loadGrammar(
      "source.binary",
      GrammarConfiguration(
        initialLanguageId: 1,
        embeddedLanguages:
          @[
            EmbeddedLanguage(scopeName: "meta.embedded", languageId: 7),
            EmbeddedLanguage(scopeName: "meta.embedded.deep", languageId: 9),
          ],
        tokenTypes:
          @[
            TokenTypeOverride(
              selector: "scope.override", tokenType: StandardTokenType.Comment
            ),
            TokenTypeOverride(
              selector: "scope.override", tokenType: StandardTokenType.RegEx
            ),
          ],
      ),
    )
    let metadata = grammar.tokenizeLine2("[x]").metadataAt(1, 3)
    check metadata.getLanguageId() == 9
    check metadata.getTokenType() == StandardTokenType.RegEx

  test "an embedded-language mapping applies at each deeper scope":
    let registry = newRegistryWithGrammar(
      """
      { "scopeName": "source.binary", "patterns": [{
        "begin": "\\[", "end": "\\]", "name": "meta.outer.long",
        "patterns": [{ "match": "x", "name": "meta.inner" }]
      }] }
    """
    )
    let grammar = registry.loadGrammar(
      "source.binary",
      GrammarConfiguration(
        embeddedLanguages:
          @[
            EmbeddedLanguage(scopeName: "meta.outer.long", languageId: 7),
            EmbeddedLanguage(scopeName: "meta.inner", languageId: 9),
          ]
      ),
    )
    check grammar.tokenizeLine2("[x]").metadataAt(1, 3).getLanguageId() == 9

  test "a deeper embedded scope resets a string token type to other":
    let registry = newRegistryWithGrammar(
      """
      { "scopeName": "source.binary", "patterns": [{
        "begin": "\\[", "end": "\\]", "name": "string.quoted",
        "patterns": [{ "match": "x", "name": "meta.embedded" }]
      }] }
    """
    )
    let metadata =
      registry.loadGrammar("source.binary").tokenizeLine2("[x]").metadataAt(1, 3)
    check metadata.getTokenType() == StandardTokenType.Other

  test "ordinary deeper scopes inherit string and comment token types":
    let registry = newRegistryWithGrammar(
      """
      { "scopeName": "source.binary", "patterns": [
        {
          "begin": "\\[", "end": "\\]", "name": "string.quoted",
          "patterns": [{ "match": "x", "name": "meta.inner" }]
        },
        {
          "begin": "\\{", "end": "\\}", "name": "comment.block",
          "patterns": [{ "match": "y", "name": "meta.inner" }]
        }
      ] }
    """
    )
    let result = registry.loadGrammar("source.binary").tokenizeLine2("[x]{y}")
    check result.metadataAt(1, 6).getTokenType() == StandardTokenType.String
    check result.metadataAt(4, 6).getTokenType() == StandardTokenType.Comment

  test "the first word-boundary semantic match controls a scope":
    let registry = newRegistryWithGrammar(
      """
      { "scopeName": "source.binary", "patterns": [
        { "match": "a", "name": "meta.regex.string" },
        { "match": "b", "name": "meta.mystring" }
      ] }
    """
    )
    let result = registry.loadGrammar("source.binary").tokenizeLine2("ab")
    check result.metadataAt(0, 2).getTokenType() == StandardTokenType.RegEx
    check result.metadataAt(1, 2).getTokenType() == StandardTokenType.Other

  test "unbalanced selectors override balanced selectors and wildcards":
    let registry = newRegistryWithGrammar(
      """
      { "scopeName": "source.binary", "patterns": [
        { "match": "x", "name": "meta.bracket" }
      ] }
    """
    )
    let grammar = registry.loadGrammar(
      "source.binary",
      GrammarConfiguration(
        balancedBracketSelectors: @["*", "meta.bracket"],
        unbalancedBracketSelectors: @["meta.bracket"],
      ),
    )
    check not grammar.tokenizeLine2("x").metadataAt(0, 1).containsBalancedBrackets()

  test "balanced selectors work without a wildcard":
    let registry = newRegistryWithGrammar(
      """
      { "scopeName": "source.binary", "patterns": [
        { "match": "x", "name": "meta.bracket" },
        { "match": "y", "name": "meta.other" }
      ] }
    """
    )
    let grammar = registry.loadGrammar(
      "source.binary", GrammarConfiguration(balancedBracketSelectors: @["meta.bracket"])
    )
    let result = grammar.tokenizeLine2("xy")
    check result.metadataAt(0, 2).containsBalancedBrackets()
    check not result.metadataAt(1, 2).containsBalancedBrackets()

  test "binary metadata coalescing respects RTL scope boundaries and empty lines":
    let registry = newRegistryWithGrammar(
      """
      { "scopeName": "source.binary", "patterns": [
        { "match": "a", "name": "meta.one" },
        { "match": "b", "name": "meta.two" }
      ] }
    """
    )
    let grammar = registry.loadGrammar("source.binary")
    let leftToRight = grammar.tokenizeLine2("ab")
    check leftToRight.tokens.len == 2
    check leftToRight.tokens[0] == 0

    let rightToLeft = grammar.tokenizeLine2("אab")
    check rightToLeft.tokens.len == 6
    check rightToLeft.tokens[0] == 0
    check rightToLeft.tokens[2] == 2
    check rightToLeft.tokens[4] == 3
    check rightToLeft.tokens[1] == rightToLeft.tokens[3]
    check rightToLeft.tokens[3] == rightToLeft.tokens[5]

    let empty = grammar.tokenizeLine2("")
    check empty.tokens.len == 2
    check empty.tokens[0] == 0

  test "font family and size spans coalesce across matching tokens":
    let registry = newRegistryWithGrammar(
      """
      { "scopeName": "source.binary", "patterns": [
        { "match": "a", "name": "meta.font" },
        { "match": "b", "name": "meta.font" }
      ] }
    """
    )
    registry.setTheme(
      parseRawTheme(
        """
      { "settings": [
        { "settings": { "foreground": "#000000", "background": "#FFFFFF" } },
        { "scope": "meta.font", "settings": {
          "fontFamily": "Mono", "fontSize": 12, "lineHeight": 18
        } }
      ] }
    """,
        "font-theme.json",
      )
    )
    let result = registry.loadGrammar("source.binary").tokenizeLine2("ab")
    check result.fonts.len == 1
    check result.fonts[0].startIndex == 0
    check result.fonts[0].endIndex == 2
    check result.fonts[0].fontFamily == "Mono"
    check result.fonts[0].fontSizeMultiplier == 12.0
    check result.fonts[0].lineHeightMultiplier == 18.0

  test "font spans leave unstyled gaps and follow theme replacement across lines":
    let registry = newRegistryWithGrammar(
      """
      { "scopeName": "source.binary", "patterns": [
        { "match": "a", "name": "meta.font" },
        { "match": "c", "name": "meta.font" },
        { "begin": "\\[", "end": "\\]", "name": "meta.multiline" }
      ] }
    """
    )
    registry.setTheme(
      parseRawTheme(
        """
        { "settings": [
          { "settings": { "foreground": "#000000", "background": "#FFFFFF" } },
          { "scope": "meta.font", "settings": {
            "fontFamily": "Mono", "fontSize": 12, "lineHeight": 18
          } },
          { "scope": "meta.multiline", "settings": { "foreground": "#112233" } }
        ] }
      """,
        "first-multiline-theme.json",
      )
    )
    let grammar = registry.loadGrammar("source.binary")
    let fonts = grammar.tokenizeLine2("abc").fonts
    check fonts.len == 2
    check fonts[0].startIndex == 0
    check fonts[0].endIndex == 1
    check fonts[1].startIndex == 2
    check fonts[1].endIndex == 3

    let firstLine = grammar.tokenizeLine2("[x")
    registry.setTheme(
      parseRawTheme(
        """
        { "settings": [
          { "settings": { "foreground": "#000000", "background": "#FFFFFF" } },
          { "scope": "meta.multiline", "settings": { "foreground": "#AABBCC" } }
        ] }
      """,
        "second-multiline-theme.json",
      )
    )
    let continued = grammar.tokenizeLine2("x]", firstLine.ruleStack)
    check registry.foregroundColor(continued.metadataAt(0, 2)) == "#AABBCC"
