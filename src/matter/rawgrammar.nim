## Raw TextMate grammar data and JSON/XML plist readers.

import std/[json, strutils, tables, xmlparser, xmltree]

type
  RawGrammarError* = object of ValueError
    ## Raised when a TextMate grammar cannot be parsed or validated.

  RawCaptures* = OrderedTable[int, RawRule]
    ## Maps a regular-expression capture number to its capture rule.

  RawRepository* = OrderedTable[string, RawRule] ## Maps repository names to rules.

  RawInjections* = OrderedTable[string, RawRule] ## Maps injection selectors to rules.

  RawRule* = ref object
    ## A raw TextMate rule. Rules are references because patterns, repositories,
    ## and captures can recursively contain more rules.
    `include`*, name*, contentName*: string
    match*, begin*, `end`*, `while`*: string
    captures*, beginCaptures*, endCaptures*, whileCaptures*: RawCaptures
    hasCaptures*, hasBeginCaptures*, hasEndCaptures*, hasWhileCaptures*: bool
    patterns*: seq[RawRule]
    repository*: RawRepository
    applyEndPatternLast*: bool

  RawCapture* = RawRule
    ## A capture entry. Capture entries use the same recursive shape as rules.

  RawGrammar* = object ## A parsed TextMate grammar.
    scopeName*, name*, firstLineMatch*, injectionSelector*: string
    fileTypes*: seq[string]
    patterns*: seq[RawRule]
    repository*: RawRepository
    injections*: RawInjections

proc fail(message: string) {.noreturn.} =
  raise newException(RawGrammarError, message)

proc requireKind(node: JsonNode, kind: JsonNodeKind, context: string) =
  if node == nil or node.kind != kind:
    fail(context & " must be a " & $kind)

proc optionalString(node: JsonNode, key, context: string): string =
  if node.hasKey(key):
    let value = node[key]
    requireKind(value, JString, context & "." & key)
    result = value.getStr()

proc optionalBool(node: JsonNode, key, context: string): bool =
  if node.hasKey(key):
    let value = node[key]
    case value.kind
    of JBool:
      result = value.getBool()
    of JInt:
      if value.getInt() notin [0, 1]:
        fail(context & "." & key & " integer value must be 0 or 1")
      result = value.getInt() == 1
    else:
      fail(context & "." & key & " must be a boolean")

proc parseCaptureNumber(key, context: string): int =
  if key.len == 0:
    fail(context & " has an empty capture number")

  for ch in key:
    if ch < '0' or ch > '9':
      fail(context & " has invalid capture number '" & key & "'")

  try:
    result = parseInt(key)
  except ValueError:
    fail(context & " has invalid capture number '" & key & "'")

proc parseRule(node: JsonNode, context: string): RawRule

proc parseCaptures(node: JsonNode, context: string): RawCaptures =
  requireKind(node, JObject, context)
  for key, value in node.pairs:
    result[parseCaptureNumber(key, context)] = parseRule(value, context & "." & key)

proc parsePatterns(node: JsonNode, context: string): seq[RawRule] =
  requireKind(node, JArray, context)
  for index in 0 ..< node.len:
    result.add(parseRule(node[index], context & "[" & $index & "]"))

proc parseRepository(node: JsonNode, context: string): RawRepository =
  requireKind(node, JObject, context)
  for key, value in node.pairs:
    result[key] = parseRule(value, context & "." & key)

proc parseRule(node: JsonNode, context: string): RawRule =
  requireKind(node, JObject, context)
  result = RawRule(
    `include`: optionalString(node, "include", context),
    name: optionalString(node, "name", context),
    contentName: optionalString(node, "contentName", context),
    match: optionalString(node, "match", context),
    begin: optionalString(node, "begin", context),
    `end`: optionalString(node, "end", context),
    `while`: optionalString(node, "while", context),
    applyEndPatternLast: optionalBool(node, "applyEndPatternLast", context),
  )

  if node.hasKey("captures"):
    result.hasCaptures = true
    result.captures = parseCaptures(node["captures"], context & ".captures")
  if node.hasKey("beginCaptures"):
    result.hasBeginCaptures = true
    result.beginCaptures =
      parseCaptures(node["beginCaptures"], context & ".beginCaptures")
  if node.hasKey("endCaptures"):
    result.hasEndCaptures = true
    result.endCaptures = parseCaptures(node["endCaptures"], context & ".endCaptures")
  if node.hasKey("whileCaptures"):
    result.hasWhileCaptures = true
    result.whileCaptures =
      parseCaptures(node["whileCaptures"], context & ".whileCaptures")
  if node.hasKey("patterns"):
    result.patterns = parsePatterns(node["patterns"], context & ".patterns")
  if node.hasKey("repository"):
    result.repository = parseRepository(node["repository"], context & ".repository")

proc parseStringArray(node: JsonNode, context: string): seq[string] =
  requireKind(node, JArray, context)
  for index in 0 ..< node.len:
    requireKind(node[index], JString, context & "[" & $index & "]")
    result.add(node[index].getStr())

proc parseGrammar(node: JsonNode): RawGrammar =
  requireKind(node, JObject, "grammar root")
  if not node.hasKey("scopeName"):
    fail("grammar root is missing scopeName")
  if not node.hasKey("patterns"):
    fail("grammar root is missing patterns")

  result.scopeName = optionalString(node, "scopeName", "grammar root")
  if result.scopeName.len == 0:
    fail("grammar root scopeName must not be empty")
  result.name = optionalString(node, "name", "grammar root")
  result.firstLineMatch = optionalString(node, "firstLineMatch", "grammar root")
  result.injectionSelector = optionalString(node, "injectionSelector", "grammar root")
  result.patterns = parsePatterns(node["patterns"], "grammar root.patterns")
  if node.hasKey("fileTypes"):
    result.fileTypes = parseStringArray(node["fileTypes"], "grammar root.fileTypes")
  if node.hasKey("repository"):
    result.repository = parseRepository(node["repository"], "grammar root.repository")
  if node.hasKey("injections"):
    result.injections = parseRepository(node["injections"], "grammar root.injections")

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
  of "true":
    if meaningfulChildren(node).len != 0:
      fail(context & " true value must be empty")
    result = newJBool(true)
  of "false":
    if meaningfulChildren(node).len != 0:
      fail(context & " false value must be empty")
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
      let keyNode = children[index]
      if keyNode.kind != xnElement or keyNode.tag != "key":
        fail(context & " dict entry must start with a key")
      result.add(
        textValue(keyNode, context & " key"),
        plistToJson(
          children[index + 1], context & "." & textValue(keyNode, context & " key")
        ),
      )
      index += 2
  else:
    fail(context & " has unsupported plist value <" & node.tag & ">")

proc parsePlist(content: string): JsonNode =
  let lowered = content.toLowerAscii()
  if "<!entity" in lowered:
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
  result = plistToJson(children[0], "plist")

proc parseRawGrammar*(content: string, filePath = ""): RawGrammar =
  ## Parses a JSON `.tmLanguage.json` or XML plist TextMate grammar.
  let root =
    try:
      if filePath.toLowerAscii().endsWith(".json"):
        parseJson(content)
      else:
        parsePlist(content)
    except RawGrammarError:
      raise
    except CatchableError as error:
      fail("invalid raw grammar: " & error.msg)
  result = parseGrammar(root)
