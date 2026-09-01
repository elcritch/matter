## TextMate scope selector parsing and matching for grammar injections.

import std/strutils

type
  SelectorPriority* = enum
    ## Injection ordering requested by a selector alternative.
    spLeft
    spDefault
    spRight

  SelectorKind = enum
    skNames
    skNever
    skNot
    skAnd
    skOr

  SelectorExpression = ref object
    case kind: SelectorKind
    of skNames:
      names: seq[string]
    of skNot:
      operand: SelectorExpression
    of skAnd, skOr:
      operands: seq[SelectorExpression]
    of skNever:
      discard

  ScopeSelector* = object
    expression: SelectorExpression
    selectorPriority: SelectorPriority

  TokenKind = enum
    tkEnd
    tkIdentifier
    tkComma
    tkPipe
    tkMinus
    tkOpenParen
    tkCloseParen

  SelectorTokenizer = object
    source: string
    position: int

  SelectorParser = object
    tokenizer: SelectorTokenizer
    tokenKind: TokenKind
    tokenText: string

func isIdentifierStart(c: char): bool =
  (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or
    c == '_' or c == '.' or c == ':'

func isIdentifierPart(c: char): bool =
  isIdentifierStart(c) or c == '-'

proc next(tokenizer: var SelectorTokenizer): tuple[kind: TokenKind, text: string] =
  while tokenizer.position < tokenizer.source.len:
    let start = tokenizer.position
    let character = tokenizer.source[tokenizer.position]
    if (character == 'L' or character == 'R') and
        tokenizer.position + 1 < tokenizer.source.len and
        tokenizer.source[tokenizer.position + 1] == ':':
      tokenizer.position += 2
      return (tkIdentifier, tokenizer.source[start ..< tokenizer.position])
    if isIdentifierStart(character):
      inc tokenizer.position
      while tokenizer.position < tokenizer.source.len and
          isIdentifierPart(tokenizer.source[tokenizer.position]):
        inc tokenizer.position
      return (tkIdentifier, tokenizer.source[start ..< tokenizer.position])

    inc tokenizer.position
    case character
    of ',':
      return (tkComma, ",")
    of '|':
      return (tkPipe, "|")
    of '-':
      return (tkMinus, "-")
    of '(':
      return (tkOpenParen, "(")
    of ')':
      return (tkCloseParen, ")")
    else:
      discard
  (tkEnd, "")

proc advance(parser: var SelectorParser) =
  let token = parser.tokenizer.next()
  parser.tokenKind = token.kind
  parser.tokenText = token.text

proc parseOperand(parser: var SelectorParser): SelectorExpression

proc parseConjunction(parser: var SelectorParser): SelectorExpression =
  var operands: seq[SelectorExpression]
  var operand = parser.parseOperand()
  while operand != nil:
    operands.add operand
    operand = parser.parseOperand()
  SelectorExpression(kind: skAnd, operands: operands)

proc parseInnerExpression(parser: var SelectorParser): SelectorExpression =
  var operands: seq[SelectorExpression]
  operands.add parser.parseConjunction()
  while parser.tokenKind == tkPipe or parser.tokenKind == tkComma:
    while parser.tokenKind == tkPipe or parser.tokenKind == tkComma:
      parser.advance()
    operands.add parser.parseConjunction()
  SelectorExpression(kind: skOr, operands: operands)

proc parseOperand(parser: var SelectorParser): SelectorExpression =
  case parser.tokenKind
  of tkMinus:
    parser.advance()
    let operand = parser.parseOperand()
    if operand == nil:
      result = SelectorExpression(kind: skNever)
    else:
      result = SelectorExpression(kind: skNot, operand: operand)
  of tkOpenParen:
    parser.advance()
    result = parser.parseInnerExpression()
    if parser.tokenKind == tkCloseParen:
      parser.advance()
  of tkIdentifier:
    var names: seq[string]
    while parser.tokenKind == tkIdentifier:
      names.add parser.tokenText
      parser.advance()
    result = SelectorExpression(kind: skNames, names: names)
  else:
    result = nil

proc parseScopeSelectors*(source: string): seq[ScopeSelector] =
  ## Parses TextMate selector alternatives. Each comma-separated top-level
  ## alternative becomes one selector, carrying its own optional L:/R: priority.
  var parser = SelectorParser(tokenizer: SelectorTokenizer(source: source))
  parser.advance()
  while parser.tokenKind != tkEnd:
    var selectorPriority = spDefault
    if parser.tokenKind == tkIdentifier and parser.tokenText.len == 2 and
        parser.tokenText[1] == ':':
      case parser.tokenText[0]
      of 'L':
        selectorPriority = spLeft
      of 'R':
        selectorPriority = spRight
      else:
        discard
      parser.advance()

    result.add ScopeSelector(
      expression: parser.parseConjunction(), selectorPriority: selectorPriority
    )
    if parser.tokenKind == tkComma:
      parser.advance()
    else:
      break

func scopeMatches(scope, name: string): bool =
  if scope.len == 0:
    return false
  if scope == name:
    return true
  scope.len > name.len and scope.startsWith(name) and scope[name.len] == '.'

func namesMatch(names: openArray[string], scopes: openArray[string]): bool =
  if scopes.len < names.len:
    return false
  var scopeIndex = 0
  for name in names:
    var found = false
    while scopeIndex < scopes.len and not found:
      if scopeMatches(scopes[scopeIndex], name):
        found = true
      inc scopeIndex
    if not found:
      return false
  true

proc matches(expression: SelectorExpression, scopes: openArray[string]): bool =
  case expression.kind
  of skNames:
    namesMatch(expression.names, scopes)
  of skNever:
    false
  of skNot:
    not expression.operand.matches(scopes)
  of skAnd:
    for operand in expression.operands:
      if not operand.matches(scopes):
        return false
    true
  of skOr:
    for operand in expression.operands:
      if operand.matches(scopes):
        return true
    false

proc matches*(selector: ScopeSelector, scopes: openArray[string]): bool =
  ## Returns whether `selector` matches an outer-to-inner TextMate scope path.
  selector.expression.matches(scopes)

func priority*(selector: ScopeSelector): SelectorPriority =
  ## Returns the injection priority attached to this selector alternative.
  selector.selectorPriority
