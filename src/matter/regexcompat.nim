## Adapt the remaining TextMate-specific regex spellings for Reni.
import std/strutils

type Replacement = object
  start, finish: int
  literal: string

proc normalizeRegex(source: string, anchors: var set[char]): string =
  var
    replacements: seq[Replacement]
    extendedStack: seq[bool]
    extended = false
    position = 0
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
      elif escaped == 'z':
        replacements.add(
          Replacement(start: start, finish: position, literal: r"$(?!\n)(?<!\n)")
        )
      elif escaped in {'p', 'P'} and (position >= source.len or source[position] != '{'):
        replacements.add(Replacement(start: start, finish: position, literal: $escaped))
    of '[':
      # Classes can nest (intersections and POSIX classes). An initial ] is
      # literal, including just after ^; escaped brackets never change depth.
      var first = @[true]
      inc position
      while position < source.len and first.len > 0:
        let ch = source[position]
        if ch == '\\':
          if position + 1 < source.len and source[position + 1] in {'p', 'P'} and
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
    of ')':
      if extendedStack.len > 0:
        extended = extendedStack.pop()
      inc position
    else:
      inc position

  var positionOut = 0
  for replacement in replacements:
    result.add(source[positionOut ..< replacement.start])
    result.add(replacement.literal)
    positionOut = replacement.finish
  result.add(source[positionOut ..^ 1])

proc textMateRegexSource*(source: string): string =
  ## Internal adapter; raw grammar regex strings remain unchanged. Reni's
  ## native capture option and per-call options handle captures and A/G.
  var anchors: set[char]
  normalizeRegex(source, anchors)

proc regexAnchors*(source: string): set[char] =
  ## Anchors outside character classes, escapes and regex comments.
  discard normalizeRegex(source, result)
