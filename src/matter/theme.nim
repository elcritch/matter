## TextMate theme parsing, resolution, and scope-path style lookup.

import std/[algorithm, json, strutils, tables, xmlparser, xmltree]

type
  ThemeError* = object of ValueError
    ## Raised when a theme is malformed or cannot be resolved.

  FontStyle* = distinct uint8
    ## A four-bit font-style mask. `fontStyleNotSet` is only used internally
    ## while resolving inherited theme settings.

  RawThemeSetting* = object ## A single unprocessed TextMate theme setting.
    name*: string
    scopes*: seq[string]
    hasFontStyle*, hasForeground*, hasBackground*, hasFontFamily*: bool
    hasFontSize*, hasLineHeight*: bool
    fontStyle*, foreground*, background*, fontFamily*: string
    fontSize*, lineHeight*: float

  RawTheme* = object ## A parsed JSON or XML plist TextMate theme.
    name*: string
    settings*: seq[RawThemeSetting]

  StyleAttributes* = object
    ## A resolved style. Color ID zero means that no rule supplied that color.
    fontStyle*: FontStyle
    foregroundId*, backgroundId*: int
    fontFamily*: string
    fontSize*, lineHeight*: float

  ResolvedThemeRule = object
    scope: string
    parentScopes: seq[string]
    index: int
    hasFontStyle*, hasForeground*, hasBackground*, hasFontFamily*: bool
    hasFontSize*, hasLineHeight*: bool
    fontStyle*: FontStyle
    foreground*, background*, fontFamily*: string
    fontSize*, lineHeight*: float

  EffectiveThemeRule = object
    scope: string
    parentScopes: seq[string]
    index: int
    style: StyleAttributes

  Theme* = ref object
    ## A resolved theme with an owned dynamic or caller-frozen color map.
    defaultStyle: StyleAttributes
    rootStyle: StyleAttributes
    rules: seq[EffectiveThemeRule]
    colors: seq[string]
    colorIds: Table[string, int]
    frozen: bool

const
  fontStyleNotSet* = FontStyle(255)
  fontStyleNone* = FontStyle(0)
  fontStyleItalic* = FontStyle(1)
  fontStyleBold* = FontStyle(2)
  fontStyleUnderline* = FontStyle(4)
  fontStyleStrikethrough* = FontStyle(8)

func fontStyleValue*(style: FontStyle): uint8 {.inline.} =
  ## Returns the representation used by binary token metadata.
  uint8(style)

func `==`*(a, b: FontStyle): bool {.inline.} =
  uint8(a) == uint8(b)

func `or`*(a, b: FontStyle): FontStyle {.inline.} =
  FontStyle(uint8(a) or uint8(b))

func contains*(style, flag: FontStyle): bool {.inline.} =
  ## Returns whether every bit in `flag` occurs in `style`.
  (uint8(style) and uint8(flag)) == uint8(flag)

proc fail(message: string) {.noreturn.} =
  raise newException(ThemeError, message)

proc requireKind(node: JsonNode, kind: JsonNodeKind, context: string) =
  if node == nil or node.kind != kind:
    fail(context & " must be a " & $kind)

func scopeMatches(scope, pattern: string): bool =
  scope == pattern or
    (
      scope.len > pattern.len and scope.startsWith(pattern) and scope[pattern.len] == '.'
    )

func isHexColor(color: string): bool =
  if color.len notin [4, 5, 7, 9] or color.len == 0 or color[0] != '#':
    return false
  for index in 1 ..< color.len:
    if color[index] notin {'0' .. '9', 'a' .. 'f', 'A' .. 'F'}:
      return false
  true

proc parseFontStyle(source: string): FontStyle =
  result = fontStyleNone
  for word in source.splitWhitespace():
    case word
    of "italic":
      result = result or fontStyleItalic
    of "bold":
      result = result or fontStyleBold
    of "underline":
      result = result or fontStyleUnderline
    of "strikethrough":
      result = result or fontStyleStrikethrough
    else:
      discard

proc optionalString(
    node: JsonNode, key, context: string, value: var string, present: var bool
) =
  if node.hasKey(key):
    requireKind(node[key], JString, context & "." & key)
    value = node[key].getStr()
    present = true

proc optionalNumber(
    node: JsonNode, key, context: string, value: var float, present: var bool
) =
  if node.hasKey(key):
    case node[key].kind
    of JInt:
      value = float(node[key].getInt())
    of JFloat:
      value = node[key].getFloat()
    else:
      fail(context & "." & key & " must be a number")
    present = true

proc parseScopes(node: JsonNode, context: string): seq[string] =
  case node.kind
  of JString:
    var source = node.getStr().strip()
    while source.len > 0 and source[0] == ',':
      source = source[1 ..^ 1]
    while source.len > 0 and source[^1] == ',':
      source.setLen(source.len - 1)
    result = source.split(',')
  of JArray:
    for index in 0 ..< node.len:
      requireKind(node[index], JString, context & "[" & $index & "]")
      result.add(node[index].getStr())
  else:
    fail(context & " must be a string or array of strings")

proc parseSetting(node: JsonNode, context: string): RawThemeSetting =
  requireKind(node, JObject, context)
  if not node.hasKey("settings"):
    fail(context & " is missing settings")
  requireKind(node["settings"], JObject, context & ".settings")
  result.scopes = @[""]
  if node.hasKey("name"):
    requireKind(node["name"], JString, context & ".name")
    result.name = node["name"].getStr()
  if node.hasKey("scope"):
    result.scopes = parseScopes(node["scope"], context & ".scope")

  let values = node["settings"]
  optionalString(
    values, "fontStyle", context & ".settings", result.fontStyle, result.hasFontStyle
  )
  optionalString(
    values, "foreground", context & ".settings", result.foreground, result.hasForeground
  )
  optionalString(
    values, "background", context & ".settings", result.background, result.hasBackground
  )
  optionalString(
    values, "fontFamily", context & ".settings", result.fontFamily, result.hasFontFamily
  )
  optionalNumber(
    values, "fontSize", context & ".settings", result.fontSize, result.hasFontSize
  )
  optionalNumber(
    values, "lineHeight", context & ".settings", result.lineHeight, result.hasLineHeight
  )
  if result.hasForeground and not isHexColor(result.foreground):
    result.hasForeground = false
    result.foreground = ""
  if result.hasBackground and not isHexColor(result.background):
    result.hasBackground = false
    result.background = ""

proc parseTheme(node: JsonNode): RawTheme =
  requireKind(node, JObject, "theme root")
  if not node.hasKey("settings"):
    fail("theme root is missing settings")
  requireKind(node["settings"], JArray, "theme root.settings")
  if node.hasKey("name"):
    requireKind(node["name"], JString, "theme root.name")
    result.name = node["name"].getStr()
  for index in 0 ..< node["settings"].len:
    let setting = node["settings"][index]
    if setting.kind == JObject and setting.hasKey("settings") and
        setting["settings"].kind != JNull:
      result.settings.add(parseSetting(setting, "theme root.settings[" & $index & "]"))

proc meaningfulChildren(node: XmlNode): seq[XmlNode] =
  for child in node:
    if child.kind notin {xnText, xnComment} or child.text.strip().len > 0:
      result.add(child)

proc decodedText(node: XmlNode): string =
  case node.kind
  of xnText, xnVerbatimText, xnCData:
    result = node.text
  of xnEntity:
    case node.text
    of "amp":
      result = "&"
    of "apos":
      result = "'"
    of "gt":
      result = ">"
    of "lt":
      result = "<"
    of "quot":
      result = "\""
    else:
      fail("unsupported XML entity '&" & node.text & ";'")
  else:
    fail("unexpected XML content")

proc textValue(node: XmlNode, context: string): string =
  for child in node:
    if child.kind in {xnText, xnVerbatimText, xnCData, xnEntity}:
      result.add(decodedText(child))
    elif child.kind != xnComment:
      fail(context & " must not contain nested elements")

proc plistToJson(node: XmlNode, context: string): JsonNode =
  if node.kind != xnElement:
    fail(context & " must be a plist value")
  case node.tag
  of "string":
    result = newJString(textValue(node, context))
  of "integer":
    try:
      result = newJInt(parseBiggestInt(textValue(node, context).strip()))
    except ValueError:
      fail(context & " has an invalid integer value")
  of "real":
    try:
      result = newJFloat(parseFloat(textValue(node, context).strip()))
    except ValueError:
      fail(context & " has an invalid real value")
  of "true":
    result = newJBool(true)
  of "false":
    result = newJBool(false)
  of "array":
    result = newJArray()
    for index, child in meaningfulChildren(node):
      result.add(plistToJson(child, context & "[" & $index & "]"))
  of "dict":
    let children = meaningfulChildren(node)
    if children.len mod 2 != 0:
      fail(context & " dict must alternate key and value elements")
    result = newJObject()
    var index = 0
    while index < children.len:
      let key = children[index]
      if key.kind != xnElement or key.tag != "key":
        fail(context & " dict entry must start with a key")
      let name = textValue(key, context & " key")
      result.add(name, plistToJson(children[index + 1], context & "." & name))
      index += 2
  else:
    fail(context & " has unsupported plist value <" & node.tag & ">")

proc parsePlist(content: string): JsonNode =
  if "<!entity" in content.toLowerAscii():
    fail("XML plist must not declare custom entities")
  let document =
    try:
      parseXml(content)
    except XmlError as error:
      fail("invalid XML plist: " & error.msg)
  if document == nil or document.kind != xnElement or document.tag != "plist":
    fail("XML plist root must be a <plist> element")
  let children = meaningfulChildren(document)
  if children.len != 1 or children[0].kind != xnElement or children[0].tag != "dict":
    fail("XML plist must contain exactly one root <dict>")
  plistToJson(children[0], "plist")

proc parseRawTheme*(content: string, filePath = ""): RawTheme =
  ## Parses a JSON theme or XML plist `.tmTheme` without resolving entities.
  let root =
    try:
      if filePath.toLowerAscii().endsWith(".json"):
        parseJson(content)
      else:
        parsePlist(content)
    except ThemeError:
      raise
    except CatchableError as error:
      fail("invalid raw theme: " & error.msg)
  result = parseTheme(root)

proc appendRules(raw: RawTheme): seq[ResolvedThemeRule] =
  for index, setting in raw.settings:
    for scope in setting.scopes:
      let parts = scope.strip().splitWhitespace()
      var rule = ResolvedThemeRule(
        index: index,
        hasFontStyle: setting.hasFontStyle,
        hasForeground: setting.hasForeground,
        hasBackground: setting.hasBackground,
        hasFontFamily: setting.hasFontFamily,
        hasFontSize: setting.hasFontSize,
        hasLineHeight: setting.hasLineHeight,
        fontStyle:
          if setting.hasFontStyle:
            parseFontStyle(setting.fontStyle)
          else:
            fontStyleNotSet,
        foreground: setting.foreground.toUpperAscii(),
        background: setting.background.toUpperAscii(),
        fontFamily: setting.fontFamily,
        fontSize: setting.fontSize,
        lineHeight: setting.lineHeight,
      )
      if parts.len > 0:
        rule.scope = parts[^1]
        if parts.len > 1:
          for parent in countdown(parts.len - 2, 0):
            rule.parentScopes.add(parts[parent])
      result.add(rule)

proc compareRuleOrder(a, b: ResolvedThemeRule): int =
  result = cmp(a.scope, b.scope)
  if result == 0:
    result = cmp(a.parentScopes.join("\x1f"), b.parentScopes.join("\x1f"))
  if result == 0:
    result = cmp(a.index, b.index)

proc colorId(theme: Theme, color: string): int =
  if color.len == 0:
    return 0
  if theme.colorIds.hasKey(color):
    return theme.colorIds[color]
  if theme.frozen:
    fail("missing color in frozen color map: " & color)
  result = theme.colors.len
  theme.colors.add(color)
  theme.colorIds[color] = result

proc apply(style: var StyleAttributes, rule: ResolvedThemeRule, theme: Theme) =
  if rule.hasFontStyle:
    style.fontStyle = rule.fontStyle
  if rule.hasForeground:
    style.foregroundId = theme.colorId(rule.foreground)
  if rule.hasBackground:
    style.backgroundId = theme.colorId(rule.background)
  if rule.hasFontFamily:
    style.fontFamily = rule.fontFamily
  if rule.hasFontSize:
    style.fontSize = rule.fontSize
  if rule.hasLineHeight:
    style.lineHeight = rule.lineHeight

func sameParentScopes(a, b: openArray[string]): bool =
  a == b

func rawRuleSpecificity(a, b: ResolvedThemeRule): int =
  result = cmp(a.scope.count('.') + 1, b.scope.count('.') + 1)
  if result == 0:
    var index = 0
    while index < a.parentScopes.len and index < b.parentScopes.len:
      if a.parentScopes[index] != ">" and b.parentScopes[index] != ">":
        result = cmp(a.parentScopes[index].len, b.parentScopes[index].len)
        if result != 0:
          return
      inc index
    result = cmp(a.parentScopes.len, b.parentScopes.len)
  if result == 0:
    result = cmp(a.index, b.index)

proc mainStyle(
    theme: Theme, rules: openArray[ResolvedThemeRule], scope: string
): StyleAttributes =
  result = theme.rootStyle
  var matching: seq[ResolvedThemeRule]
  for rule in rules:
    if rule.parentScopes.len == 0 and scopeMatches(scope, rule.scope):
      matching.add(rule)
  matching.sort(rawRuleSpecificity)
  for rule in matching:
    result.apply(rule, theme)

proc addEffectiveRules(theme: Theme, rawRules: openArray[ResolvedThemeRule]) =
  for rule in rawRules:
    var seen = false
    for existing in theme.rules:
      if existing.scope == rule.scope and
          sameParentScopes(existing.parentScopes, rule.parentScopes):
        seen = true
    if not seen:
      var style = theme.mainStyle(rawRules, rule.scope)
      if rule.parentScopes.len > 0:
        var matching: seq[ResolvedThemeRule]
        for candidate in rawRules:
          if candidate.scope == rule.scope and
              sameParentScopes(candidate.parentScopes, rule.parentScopes):
            matching.add(candidate)
        matching.sort(
          proc(a, b: ResolvedThemeRule): int =
            cmp(a.index, b.index)
        )
        for candidate in matching:
          style.apply(candidate, theme)
      theme.rules.add(
        EffectiveThemeRule(
          scope: rule.scope,
          parentScopes: rule.parentScopes,
          index: rule.index,
          style: style,
        )
      )

proc newThemeImpl(raw: RawTheme, frozenColors: seq[string], frozen: bool): Theme =
  new(result)
  result.frozen = frozen
  result.colors = @[""]
  result.colorIds = initTable[string, int]()
  result.colorIds[""] = 0
  if frozen:
    if frozenColors.len == 0 or frozenColors[0] != "":
      fail("a frozen color map must reserve an empty color at index zero")
    result.colors.setLen(0)
    for index, color in frozenColors:
      if index > 0 and not isHexColor(color):
        fail("frozen color map contains an invalid color: " & color)
      let normalized = color.toUpperAscii()
      result.colors.add(normalized)
      result.colorIds[normalized] = index

  var allRules = appendRules(raw)
  allRules.sort(compareRuleOrder)
  result.defaultStyle = StyleAttributes(fontStyle: fontStyleNone)
  var nonDefault: seq[ResolvedThemeRule]
  for rule in allRules:
    if rule.scope.len == 0:
      result.defaultStyle.apply(rule, result)
    else:
      nonDefault.add(rule)
  if result.defaultStyle.foregroundId == 0:
    result.defaultStyle.foregroundId = result.colorId("#000000")
  if result.defaultStyle.backgroundId == 0:
    result.defaultStyle.backgroundId = result.colorId("#FFFFFF")
  for rule in nonDefault:
    if rule.hasForeground:
      discard result.colorId(rule.foreground)
    if rule.hasBackground:
      discard result.colorId(rule.background)
  result.rootStyle = StyleAttributes(
    fontStyle: fontStyleNotSet,
    fontFamily: result.defaultStyle.fontFamily,
    fontSize: result.defaultStyle.fontSize,
    lineHeight: result.defaultStyle.lineHeight,
  )
  result.addEffectiveRules(nonDefault)

proc newTheme*(raw: RawTheme): Theme =
  ## Resolves a theme and allocates color IDs in deterministic rule order.
  newThemeImpl(raw, @[], false)

proc newTheme*(raw: RawTheme, colorMap: openArray[string]): Theme =
  ## Resolves a theme against caller-owned, frozen color IDs.
  newThemeImpl(raw, @colorMap, true)

proc defaults*(theme: Theme): StyleAttributes =
  ## Returns the fully resolved default style.
  theme.defaultStyle

proc colorMap*(theme: Theme): seq[string] =
  ## Returns a copy of index-to-color mappings; index zero is always empty.
  result = newSeq[string](theme.colors.len)
  for index, color in theme.colors:
    result[index] = color

func parentScopesMatch(
    scopePath: openArray[string], parentScopes: openArray[string]
): bool =
  if parentScopes.len == 0:
    return true
  var pathIndex = scopePath.len - 2
  var patternIndex = 0
  while patternIndex < parentScopes.len:
    var pattern = parentScopes[patternIndex]
    var immediate = false
    if pattern == ">":
      inc patternIndex
      if patternIndex >= parentScopes.len:
        return false
      pattern = parentScopes[patternIndex]
      immediate = true
    var matched = false
    while pathIndex >= 0 and not matched:
      if scopeMatches(scopePath[pathIndex], pattern):
        matched = true
      elif immediate:
        return false
      else:
        dec pathIndex
    if not matched:
      return false
    dec pathIndex
    inc patternIndex
  true

func effectiveRuleSpecificity(a, b: EffectiveThemeRule): int =
  result = cmp(b.scope.count('.') + 1, a.scope.count('.') + 1)
  if result == 0:
    var aIndex = 0
    var bIndex = 0
    while aIndex < a.parentScopes.len and bIndex < b.parentScopes.len:
      if a.parentScopes[aIndex] == ">":
        inc aIndex
      if b.parentScopes[bIndex] == ">":
        inc bIndex
      if aIndex >= a.parentScopes.len or bIndex >= b.parentScopes.len:
        break
      result = cmp(b.parentScopes[bIndex].len, a.parentScopes[aIndex].len)
      if result != 0:
        return
      inc aIndex
      inc bIndex
    result = cmp(b.parentScopes.len, a.parentScopes.len)
  if result == 0:
    result = cmp(a.index, b.index)

proc match*(theme: Theme, scopePath: openArray[string]): StyleAttributes =
  ## Resolves style attributes for an outer-to-inner TextMate scope path.
  if scopePath.len == 0:
    return theme.defaultStyle
  result = theme.rootStyle
  let leaf = scopePath[^1]
  var matches: seq[EffectiveThemeRule]
  for rule in theme.rules:
    if scopeMatches(leaf, rule.scope) and parentScopesMatch(
      scopePath, rule.parentScopes
    ):
      matches.add(rule)
  matches.sort(effectiveRuleSpecificity)
  if matches.len > 0:
    result = matches[0].style
