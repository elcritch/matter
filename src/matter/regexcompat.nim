## Preserve TextMate's capture-group numbering with Reni's named-group mode.
## VS Code enables ONIG_OPTION_CAPTURE_GROUP. Reni otherwise drops unnamed
## captures whenever a pattern contains named groups. Give ordinary captures
## private names so both kinds retain their original indices.

import std/[sequtils, strutils]

import pkg/reni

type Replacement = object
  start, finish, capture: int
  opening: bool
  literal: string

proc referenceNumber(source: string): int =
  # Report malformed/overflowing indices through the grammar error contract.
  let first = if source.len > 0 and source[0] in {'+', '-'}: 1 else: 0
  if first == source.len:
    raise newException(RegexError, "invalid numeric capture reference")
  for index in first ..< source.len:
    let digit = source[index].ord - '0'.ord
    if digit notin 0 .. 9 or result > (high(int) - digit) div 10:
      raise newException(RegexError, "invalid numeric capture reference")
    result = result * 10 + digit
  if first == 1 and source[0] == '-':
    result = -result

proc normalizeRegex(
    source: string, allowA, allowG: bool, anchors: var set[char], anchorsOnly = false
): string =
  var
    names = @[""] # Capture zero is the whole expression.
    replacements: seq[Replacement]
    extendedStack: seq[bool]
    extended = false
    hasNamed = false
    position = 0
    privatePrefix = "matterCapture"
  while source.contains(privatePrefix):
    privatePrefix.add('_')

  proc reference(start, finish, index: int) =
    replacements.add(Replacement(start: start, finish: finish, capture: index))

  while position < source.len:
    let start = position
    case source[position]
    of '\\':
      position += min(2, source.len - position)
      if position - start < 2:
        continue
      let escaped = source[start + 1]
      if escaped == 'Q':
        let close = source.find(r"\E", position)
        position =
          if close < 0:
            source.len
          else:
            close + 2
      elif escaped in {'A', 'G', 'K'}:
        anchors.incl(escaped)
        if (escaped == 'A' and not allowA) or (escaped == 'G' and not allowG):
          replacements.add(Replacement(start: start, finish: position, literal: "(?!)"))
      elif escaped == 'z' and not anchorsOnly:
        replacements.add(
          Replacement(start: start, finish: position, literal: r"$(?!\n)(?<!\n)(?!\z)")
        )
      elif escaped in {'p', 'P'} and not anchorsOnly and
          (position >= source.len or source[position] != '{'):
        replacements.add(Replacement(start: start, finish: position, literal: $escaped))
      elif escaped in {'1' .. '9'}:
        while position < source.len and source[position].isDigit:
          inc position
        let number = referenceNumber(source[start + 1 ..< position])
        # Longer invalid references are octal escapes in Oniguruma/Reni.
        if position == start + 2 or number < names.len:
          reference(start, position, number)
      elif escaped in {'k', 'g'} and position < source.len and
          source[position] in {'<', '\''}:
        let close = if source[position] == '<': '>' else: '\''
        let first = position + 1
        let last = source.find(close, first)
        if last >= 0:
          let target = source[first ..< last]
          if target.len > 0 and (
            target.allCharsInSet({'0' .. '9'}) or (
              target.len > 1 and target[0] in {'+', '-'} and
              target[1 ..^ 1].allCharsInSet({'0' .. '9'})
            )
          ):
            var number = referenceNumber(target)
            if target[0] == '-':
              number = names.len + number
            elif target[0] == '+':
              number += names.len - 1
            if number > 0:
              replacements.add(Replacement(start: first, finish: last, capture: number))
          position = last + 1
    of '[':
      # Classes can nest (intersections and POSIX classes). An initial ] is
      # literal, including just after ^; escaped brackets never change depth.
      var first = @[true]
      inc position
      while position < source.len and first.len > 0:
        let ch = source[position]
        if ch == '\\':
          if not anchorsOnly and position + 1 < source.len and
              source[position + 1] in {'p', 'P'} and
              (position + 2 >= source.len or source[position + 2] != '{'):
            replacements.add(
              Replacement(
                start: position, finish: position + 2, literal: $source[position + 1]
              )
            )
          position += min(2, source.len - position)
          first[^1] = false
          continue
        if ch == '[':
          first[^1] = false
          first.add(true)
        elif ch == ']' and not first[^1]:
          first.setLen(first.len - 1)
        elif ch != '^' or not first[^1]:
          first[^1] = false
        inc position
    of '#':
      if extended:
        while position < source.len and source[position] != '\n':
          inc position
      else:
        inc position
    of '(':
      inc position
      if position >= source.len or source[position] != '?':
        names.add(privatePrefix & $names.len)
        replacements.add(
          Replacement(
            start: start, finish: position, capture: names.high, opening: true
          )
        )
        extendedStack.add(extended)
        continue
      inc position
      if position < source.len and source[position] == '#':
        let close = source.find(')', position + 1)
        position =
          if close < 0:
            source.len
          else:
            close + 1
        continue
      let flagStart = position
      var changedExtended = extended
      var enable = true
      while position < source.len and
          source[position] in {'i', 'm', 'x', 'W', 'D', 'S', 'P', 'I', 'L', '-'}:
        if source[position] == '-':
          enable = false
        elif source[position] == 'x':
          changedExtended = enable
        inc position
      if position > flagStart and position < source.len and source[position] == ')':
        extended = changedExtended
        inc position
        continue
      extendedStack.add(extended)
      extended = changedExtended
      if position > flagStart:
        continue
      var nameStart = -1
      var delimiter = '>'
      if position < source.len:
        if source[position] == '<' and position + 1 < source.len and
            source[position + 1] notin {'=', '!'}:
          nameStart = position + 1
        elif source[position] == '\'':
          nameStart = position + 1
          delimiter = '\''
        elif source[position] == 'P' and position + 1 < source.len and
            source[position + 1] == '<':
          nameStart = position + 2
      if nameStart >= 0:
        let close = source.find(delimiter, nameStart)
        if close >= 0:
          names.add(source[nameStart ..< close])
          hasNamed = true
          position = close + 1
      elif position + 1 < source.len and source[position] == '(' and
          source[position + 1] in {'0' .. '9', '-'}:
        let close = source.find(')', position + 1)
        if close >= 0:
          var number = referenceNumber(source[position + 1 ..< close])
          if number < 0:
            number += names.len
          replacements.add(
            Replacement(start: position + 1, finish: close, capture: number)
          )
          position = close + 1
    of '^', '$':
      # Oniguruma's line anchors do not match the empty position after the
      # terminal newline. Reni also tries that position; exclude it explicitly.
      if not anchorsOnly:
        replacements.add(
          Replacement(
            start: position,
            finish: position + 1,
            literal: $source[position] & r"(?!\z)",
          )
        )
      inc position
    of ')':
      if extendedStack.len > 0:
        extended = extendedStack.pop()
      inc position
    else:
      inc position

  var positionOut = 0
  for replacement in replacements:
    if replacement.literal.len > 0:
      result.add(source[positionOut ..< replacement.start])
      result.add(replacement.literal)
      positionOut = replacement.finish
      continue
    if anchorsOnly or not hasNamed:
      continue
    if replacement.capture <= 0 or replacement.capture >= names.len:
      continue # Let the regex compiler diagnose invalid references.
    result.add(source[positionOut ..< replacement.start])
    let name = names[replacement.capture]
    if not replacement.opening and names.count(name) > 1:
      # A name would refer to several groups, changing a numeric reference's
      # target. Reni cannot address one duplicate by number in named mode.
      raise newException(
        RegexError, "numeric reference to a duplicate capture name: " & name
      )
    if replacement.opening:
      result.add("(?<" & name & ">")
    elif source[replacement.start] == '\\':
      result.add("\\k<" & name & ">")
    else:
      result.add(name)
    positionOut = replacement.finish
  result.add(source[positionOut ..^ 1])

proc textMateRegexSource*(
    source: string, allowA = true, allowG = true, anchorsOnly = false
): string =
  ## Internal adapter; raw grammar regex strings remain unchanged.
  ## `anchorsOnly` disables anchors in an already adapted regex source.
  var anchors: set[char]
  normalizeRegex(source, allowA, allowG, anchors, anchorsOnly)

proc regexAnchors*(source: string): set[char] =
  ## Anchors outside character classes, escapes and regex comments.
  discard normalizeRegex(source, true, true, result)
