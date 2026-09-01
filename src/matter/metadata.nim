## The stable 32-bit TextMate token metadata layout.

import std/options

import ./theme

type
  EncodedTokenAttributes* = uint32
    ## Packed TextMate token metadata. Its bit layout matches vscode-textmate.

  StandardTokenType* {.pure.} = enum
    ## The standard semantic token classes stored in metadata bits 8 through 9.
    Other = 0
    Comment = 1
    String = 2
    RegEx = 3

  OptionalStandardTokenType* {.pure.} = enum
    ## A standard token type or ``NotSet`` for a non-replacing metadata update.
    Other = 0
    Comment = 1
    String = 2
    RegEx = 3
    NotSet = 8

const
  languageIdOffset* = 0
  ## Offset of the eight-bit language ID field.
  tokenTypeOffset* = 8
  ## Offset of the two-bit standard token type field.
  balancedBracketsOffset* = 10
  ## Offset of the balanced-bracket bit.
  fontStyleOffset* = 11
  ## Offset of the four-bit font-style field.
  foregroundOffset* = 15
  ## Offset of the nine-bit foreground color ID field.
  backgroundOffset* = 24
  ## Offset of the eight-bit background color ID field.
  languageIdMask* = 0x000000ff'u32
  tokenTypeMask* = 0x00000300'u32
  balancedBracketsMask* = 0x00000400'u32
  fontStyleMask* = 0x00007800'u32
  foregroundMask* = 0x00ff8000'u32
  backgroundMask* = 0xff000000'u32

func getLanguageId*(metadata: EncodedTokenAttributes): uint32 =
  ## Returns the packed language ID.
  (metadata and languageIdMask) shr languageIdOffset

func getTokenType*(metadata: EncodedTokenAttributes): StandardTokenType =
  ## Returns the standard semantic token type.
  StandardTokenType((metadata and tokenTypeMask) shr tokenTypeOffset)

func containsBalancedBrackets*(metadata: EncodedTokenAttributes): bool =
  ## Returns whether the balanced-bracket bit is set.
  (metadata and balancedBracketsMask) != 0

func getFontStyle*(metadata: EncodedTokenAttributes): FontStyle =
  ## Returns the four packed font-style flags.
  FontStyle((metadata and fontStyleMask) shr fontStyleOffset)

func getForeground*(metadata: EncodedTokenAttributes): uint32 =
  ## Returns the foreground color ID.
  (metadata and foregroundMask) shr foregroundOffset

func getBackground*(metadata: EncodedTokenAttributes): uint32 =
  ## Returns the background color ID.
  (metadata and backgroundMask) shr backgroundOffset

func toOptionalTokenType*(tokenType: StandardTokenType): OptionalStandardTokenType =
  ## Converts a standard token type into its replaceable counterpart.
  case tokenType
  of StandardTokenType.Other: OptionalStandardTokenType.Other
  of StandardTokenType.Comment: OptionalStandardTokenType.Comment
  of StandardTokenType.String: OptionalStandardTokenType.String
  of StandardTokenType.RegEx: OptionalStandardTokenType.RegEx

func fromOptionalTokenType(tokenType: OptionalStandardTokenType): StandardTokenType =
  case tokenType
  of OptionalStandardTokenType.Other: StandardTokenType.Other
  of OptionalStandardTokenType.Comment: StandardTokenType.Comment
  of OptionalStandardTokenType.String: StandardTokenType.String
  of OptionalStandardTokenType.RegEx: StandardTokenType.RegEx
  of OptionalStandardTokenType.NotSet: StandardTokenType.Other

func set*(
    metadata: EncodedTokenAttributes,
    languageId: uint32,
    tokenType: OptionalStandardTokenType,
    balancedBrackets: Option[bool],
    fontStyle: FontStyle,
    foreground, background: uint32,
): EncodedTokenAttributes =
  ## Updates packed metadata fields.
  ##
  ## A zero language/color ID, ``NotSet`` token type, absent balanced-bracket
  ## value, or ``fontStyleNotSet`` preserves the corresponding existing field.
  var updatedLanguageId = metadata.getLanguageId()
  var updatedTokenType = metadata.getTokenType()
  var updatedBalancedBrackets = metadata.containsBalancedBrackets()
  var updatedFontStyle = metadata.getFontStyle()
  var updatedForeground = metadata.getForeground()
  var updatedBackground = metadata.getBackground()

  if languageId != 0:
    updatedLanguageId = languageId
  if tokenType != OptionalStandardTokenType.NotSet:
    updatedTokenType = fromOptionalTokenType(tokenType)
  if balancedBrackets.isSome:
    updatedBalancedBrackets = balancedBrackets.get
  if fontStyle.fontStyleValue != fontStyleNotSet.fontStyleValue:
    updatedFontStyle = fontStyle
  if foreground != 0:
    updatedForeground = foreground
  if background != 0:
    updatedBackground = background

  (updatedLanguageId shl languageIdOffset) or
    (uint32(updatedTokenType) shl tokenTypeOffset) or
    ((if updatedBalancedBrackets: 1'u32 else: 0'u32) shl balancedBracketsOffset) or
    (uint32(fontStyleValue(updatedFontStyle)) shl fontStyleOffset) or
    (updatedForeground shl foregroundOffset) or (updatedBackground shl backgroundOffset)
