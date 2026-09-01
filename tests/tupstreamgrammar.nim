## Ports the enabled metadata and font tests from
## vscode-textmate/src/tests/grammar.test.ts at
## fbe49961ab8077e587fdf5282019655ae69e5f9e.

import std/[options, unittest]

import matter/[engine, metadata, rawgrammar, theme]

proc assertEquals(
    metadata: EncodedTokenAttributes,
    languageId: uint32,
    tokenType: StandardTokenType,
    containsBalancedBrackets: bool,
    fontStyle: FontStyle,
    foreground, background: uint32,
) =
  doAssert metadata.getLanguageId() == languageId
  doAssert metadata.getTokenType() == tokenType
  doAssert metadata.containsBalancedBrackets() == containsBalancedBrackets
  doAssert metadata.getFontStyle() == fontStyle
  doAssert metadata.getForeground() == foreground
  doAssert metadata.getBackground() == background

suite "vscode-textmate grammar.test.ts compatibility":
  test "StackElementMetadata works":
    let value = set(
      0'u32,
      1,
      OptionalStandardTokenType.RegEx,
      some(false),
      fontStyleUnderline.or(fontStyleBold),
      101,
      102,
    )
    assertEquals(
      value,
      1,
      StandardTokenType.RegEx,
      false,
      fontStyleUnderline.or(fontStyleBold),
      101,
      102,
    )

  test "StackElementMetadata can overwrite languageId":
    var value = set(
      0'u32,
      1,
      OptionalStandardTokenType.RegEx,
      some(false),
      fontStyleUnderline.or(fontStyleBold),
      101,
      102,
    )
    assertEquals(
      value,
      1,
      StandardTokenType.RegEx,
      false,
      fontStyleUnderline.or(fontStyleBold),
      101,
      102,
    )

    value = set(
      value, 2, OptionalStandardTokenType.NotSet, some(false), fontStyleNotSet, 0, 0
    )
    assertEquals(
      value,
      2,
      StandardTokenType.RegEx,
      false,
      fontStyleUnderline.or(fontStyleBold),
      101,
      102,
    )

  test "StackElementMetadata can overwrite tokenType":
    var value = set(
      0'u32,
      1,
      OptionalStandardTokenType.RegEx,
      some(false),
      fontStyleUnderline.or(fontStyleBold),
      101,
      102,
    )
    assertEquals(
      value,
      1,
      StandardTokenType.RegEx,
      false,
      fontStyleUnderline.or(fontStyleBold),
      101,
      102,
    )

    value = set(
      value, 0, OptionalStandardTokenType.Comment, some(false), fontStyleNotSet, 0, 0
    )
    assertEquals(
      value,
      1,
      StandardTokenType.Comment,
      false,
      fontStyleUnderline.or(fontStyleBold),
      101,
      102,
    )

  test "StackElementMetadata can overwrite font style":
    var value = set(
      0'u32,
      1,
      OptionalStandardTokenType.RegEx,
      some(false),
      fontStyleUnderline.or(fontStyleBold),
      101,
      102,
    )
    assertEquals(
      value,
      1,
      StandardTokenType.RegEx,
      false,
      fontStyleUnderline.or(fontStyleBold),
      101,
      102,
    )

    value =
      set(value, 0, OptionalStandardTokenType.NotSet, some(false), fontStyleNone, 0, 0)
    assertEquals(value, 1, StandardTokenType.RegEx, false, fontStyleNone, 101, 102)

  test "StackElementMetadata can overwrite font style with strikethrough":
    var value = set(
      0'u32,
      1,
      OptionalStandardTokenType.RegEx,
      some(false),
      fontStyleStrikethrough,
      101,
      102,
    )
    assertEquals(
      value, 1, StandardTokenType.RegEx, false, fontStyleStrikethrough, 101, 102
    )

    value =
      set(value, 0, OptionalStandardTokenType.NotSet, some(false), fontStyleNone, 0, 0)
    assertEquals(value, 1, StandardTokenType.RegEx, false, fontStyleNone, 101, 102)

  test "StackElementMetadata can overwrite foreground":
    var value = set(
      0'u32,
      1,
      OptionalStandardTokenType.RegEx,
      some(false),
      fontStyleUnderline.or(fontStyleBold),
      101,
      102,
    )
    assertEquals(
      value,
      1,
      StandardTokenType.RegEx,
      false,
      fontStyleUnderline.or(fontStyleBold),
      101,
      102,
    )

    value = set(
      value, 0, OptionalStandardTokenType.NotSet, some(false), fontStyleNotSet, 5, 0
    )
    assertEquals(
      value,
      1,
      StandardTokenType.RegEx,
      false,
      fontStyleUnderline.or(fontStyleBold),
      5,
      102,
    )

  test "StackElementMetadata can overwrite background":
    var value = set(
      0'u32,
      1,
      OptionalStandardTokenType.RegEx,
      some(false),
      fontStyleUnderline.or(fontStyleBold),
      101,
      102,
    )
    assertEquals(
      value,
      1,
      StandardTokenType.RegEx,
      false,
      fontStyleUnderline.or(fontStyleBold),
      101,
      102,
    )

    value = set(
      value, 0, OptionalStandardTokenType.NotSet, some(false), fontStyleNotSet, 0, 7
    )
    assertEquals(
      value,
      1,
      StandardTokenType.RegEx,
      false,
      fontStyleUnderline.or(fontStyleBold),
      101,
      7,
    )

  test "StackElementMetadata can overwrite balanced backet bit":
    var value = set(
      0'u32,
      1,
      OptionalStandardTokenType.RegEx,
      some(false),
      fontStyleUnderline.or(fontStyleBold),
      101,
      102,
    )
    assertEquals(
      value,
      1,
      StandardTokenType.RegEx,
      false,
      fontStyleUnderline.or(fontStyleBold),
      101,
      102,
    )

    value =
      set(value, 0, OptionalStandardTokenType.NotSet, some(true), fontStyleNotSet, 0, 0)
    assertEquals(
      value,
      1,
      StandardTokenType.RegEx,
      true,
      fontStyleUnderline.or(fontStyleBold),
      101,
      102,
    )

    value = set(
      value, 0, OptionalStandardTokenType.NotSet, some(false), fontStyleNotSet, 0, 0
    )
    assertEquals(
      value,
      1,
      StandardTokenType.RegEx,
      false,
      fontStyleUnderline.or(fontStyleBold),
      101,
      102,
    )

  test "StackElementMetadata can work at max values":
    let value = set(
      0'u32,
      255,
      OptionalStandardTokenType.RegEx,
      some(true),
      fontStyleBold.or(fontStyleItalic).or(fontStyleUnderline),
      511,
      254,
    )
    assertEquals(
      value,
      255,
      StandardTokenType.RegEx,
      true,
      fontStyleBold.or(fontStyleItalic).or(fontStyleUnderline),
      511,
      254,
    )

  test "Fonts are correctly set":
    let registry = newRegistry()
    registry.setTheme(
      parseRawTheme(
        """
        { "settings": [{
          "scope": "bar.test",
          "settings": {
            "fontFamily": "monospace", "fontSize": 1.2, "lineHeight": 3
          }
        }] }
        """,
        "fonts-are-correctly-set.json",
      )
    )
    registry.addGrammar(
      parseRawGrammar(
        """
        { "scopeName": "source.test", "patterns": [
          { "match": "\\bbar\\b", "name": "bar.test" }
        ] }
        """,
        "fonts-are-correctly-set.tmLanguage.json",
      )
    )
    let result = registry.loadGrammar("source.test").tokenizeLine2("bar hello")
    doAssert result.fonts ==
      @[
        FontInfo(
          startIndex: 0,
          endIndex: 3,
          fontFamily: "monospace",
          fontSizeMultiplier: 1.2,
          lineHeightMultiplier: 3,
        )
      ]

  test "Fonts are correctly set 2":
    let registry = newRegistry()
    registry.setTheme(
      parseRawTheme(
        """
        { "settings": [{
          "scope": "entity.name.function.ts",
          "settings": {
            "fontFamily": "Times New Roman", "fontSize": 1.3, "lineHeight": 3
          }
        }] }
        """,
        "fonts-are-correctly-set-2.json",
      )
    )
    registry.addGrammar(
      parseRawGrammar(
        """
        { "scopeName": "source.ts", "patterns": [
          { "match": "g", "name": "entity.name.function.ts" }
        ] }
        """,
        "fonts-are-correctly-set-2.tmLanguage.json",
      )
    )
    let result = registry.loadGrammar("source.ts").tokenizeLine2("function g() {}")
    doAssert result.fonts ==
      @[
        FontInfo(
          startIndex: 9,
          endIndex: 10,
          fontFamily: "Times New Roman",
          fontSizeMultiplier: 1.3,
          lineHeightMultiplier: 3,
        )
      ]
