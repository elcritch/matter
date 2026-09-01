import std/[options, unittest]

import matter/[metadata, theme]

suite "encoded token metadata":
  test "pack and decode the vscode-textmate reference vector":
    let metadata = set(
      0'u32,
      1,
      StandardTokenType.String.toOptionalTokenType(),
      some(true),
      fontStyleItalic.or(fontStyleBold),
      511,
      128,
    )
    check metadata == 0x80ff9e01'u32
    check metadata.getLanguageId() == 1
    check metadata.getTokenType() == StandardTokenType.String
    check metadata.containsBalancedBrackets()
    check metadata.getFontStyle().fontStyleValue == 3
    check metadata.getForeground() == 511
    check metadata.getBackground() == 128

  test "pack and decode the upstream primary vector":
    let metadata = set(
      0'u32,
      1,
      OptionalStandardTokenType.RegEx,
      some(false),
      fontStyleUnderline.or(fontStyleBold),
      101,
      102,
    )
    check metadata == 0x6632b301'u32
    check metadata.getLanguageId() == 1
    check metadata.getTokenType() == StandardTokenType.RegEx
    check not metadata.containsBalancedBrackets()
    check metadata.getFontStyle().fontStyleValue == 6
    check metadata.getForeground() == 101
    check metadata.getBackground() == 102

  test "preserve fields for the reference not-set values":
    let original = 0x80ff9e01'u32
    let unchanged = set(
      original, 0, OptionalStandardTokenType.NotSet, none(bool), fontStyleNotSet, 0, 0
    )
    check unchanged == original

  test "replace individual fields without retaining old bits":
    let updated = set(
      0x80ff9e01'u32,
      42,
      OptionalStandardTokenType.Comment,
      some(false),
      fontStyleUnderline,
      7,
      255,
    )
    check updated == 0xff03a12a'u32
    check updated.getLanguageId() == 42
    check updated.getTokenType() == StandardTokenType.Comment
    check not updated.containsBalancedBrackets()
    check updated.getFontStyle().fontStyleValue == fontStyleUnderline.fontStyleValue
    check updated.getForeground() == 7
    check updated.getBackground() == 255

  test "keep unsigned high-bit background values":
    let metadata = set(
      0'u32,
      255,
      OptionalStandardTokenType.RegEx,
      some(true),
      fontStyleStrikethrough.or(fontStyleUnderline).or(fontStyleBold).or(
        fontStyleItalic
      ),
      511,
      255,
    )
    check metadata == high(uint32)
    check metadata.getBackground() == 255
    check metadata.getForeground() == 511
    check metadata.getFontStyle().fontStyleValue == 15

  test "expose the reference field masks and offsets":
    check languageIdOffset == 0
    check tokenTypeOffset == 8
    check balancedBracketsOffset == 10
    check fontStyleOffset == 11
    check foregroundOffset == 15
    check backgroundOffset == 24
    check languageIdMask == 0x000000ff'u32
    check tokenTypeMask == 0x00000300'u32
    check balancedBracketsMask == 0x00000400'u32
    check fontStyleMask == 0x00007800'u32
    check foregroundMask == 0x00ff8000'u32
    check backgroundMask == 0xff000000'u32
