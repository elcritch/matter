## Compilation and incremental tokenization for TextMate grammars.

import std/[algorithm, monotimes, sets, strutils, tables, times]

import pkg/reni

import ./[rawgrammar, selectors]

type
  MatterError* = object of ValueError ## A grammar could not be compiled or tokenized.

  RuleKind = enum
    rkInclude
    rkMatch
    rkBeginEnd
    rkBeginWhile

  CompiledCapture = object
    name, contentName: string
    rule: CompiledRule

  CompiledRule = ref object
    kind: RuleKind
    name, contentName: string
    matchSource, beginSource, endSource, whileSource: string
    matchRegex, beginRegex: Regex
    captures, beginCaptures, endCaptures, whileCaptures:
      OrderedTable[int, CompiledCapture]
    patterns: seq[CompiledRule]
    applyEndPatternLast: bool

  Injection = object
    selector: ScopeSelector
    rule: CompiledRule

  Registry* = ref object
    grammars: OrderedTable[string, RawGrammar]
    injectionScopes: Table[string, seq[string]]

  Grammar* = ref object
    scopeName: string
    root: CompiledRule
    injections: seq[Injection]

  StateStack* = ref object
    ## An immutable active begin/end or begin/while nesting frame.
    parent: StateStack
    rule: CompiledRule
    nameScopes: seq[string]
    scopes: seq[string]
    endRegex: Regex
    hasEndRegex: bool
    enterPos: int
    anchorPos: int
    isRoot: bool
    isFirstLine: bool
    beginRuleCapturedEol: bool

  Token* = object
    ## A half-open UTF-8 byte range with the active outer-to-inner scope path.
    startIndex*, endIndex*: int
    scopes*: seq[string]

  TokenizeLineResult* = object
    tokens*: seq[Token]
    ruleStack*: StateStack
    stoppedEarly*: bool

  CandidateKind = enum
    ckRule
    ckEnd

  Candidate = object
    found: bool
    kind: CandidateKind
    rule: CompiledRule
    matched: Match

var matchContext {.threadvar.}: MatchContext

proc searchWithContext(subject: string, regex: Regex, start: int): Match =
  ## Reuse reni's per-thread scratch buffers across all tokenizer probes.
  if matchContext.isNil:
    matchContext = newMatchContext(regex.captureCount)
  discard searchIntoCtx(matchContext, subject, regex, result, start)

proc newRegistry*(): Registry =
  ## Create an empty grammar registry.
  Registry(
    grammars: initOrderedTable[string, RawGrammar](),
    injectionScopes: initTable[string, seq[string]](),
  )

proc addGrammar*(registry: Registry, grammar: RawGrammar) =
  ## Add or replace a raw grammar, registering injection grammars by selector scope.
  if grammar.scopeName.len == 0:
    raise newException(MatterError, "grammar scopeName must not be empty")
  registry.grammars[grammar.scopeName] = grammar
  if grammar.injectionSelector.len > 0:
    for target in grammar.injectionSelector.split(','):
      let scope = target.strip(chars = {' ', 'L', 'R', ':'})
      if scope.len > 0:
        registry.injectionScopes.mgetOrPut(scope, @[]).add(grammar.scopeName)

proc addGrammar*(
    registry: Registry, grammar: RawGrammar, hostScopes: openArray[string]
) =
  ## Add a grammar and register its name as a host-provided injection for each scope.
  ## This mirrors vscode-textmate's registry injection-name mapping; ``hostScopes``
  ## are scopes tokenized by other grammars, not selectors in ``grammar`` itself.
  registry.addGrammar(grammar)
  for scope in hostScopes:
    registry.injectionScopes.mgetOrPut(scope, @[]).add(grammar.scopeName)

proc resolveAnchors(source: string, allowA = true, allowG = true): string =
  ## Keep real anchors when enabled; disable only the anchor branch otherwise.
  var position = 0
  while position < source.len:
    if source[position] == '\\' and position + 1 < source.len:
      let escaped = source[position + 1]
      case escaped
      of 'z':
        result.add("$(?!\\n)(?<!\\n)")
      of 'A':
        result.add(if allowA: "\\A" else: "(?!)")
      of 'G':
        result.add(if allowG: "\\G" else: "(?!)")
      else:
        result.add(source[position])
        result.add(escaped)
      position += 2
    else:
      result.add(source[position])
      inc position

proc regexFor(source, context: string, allowA = true, allowG = true): Regex =
  let normalized = resolveAnchors(source, allowA, allowG)
  try:
    re(normalized)
  except RegexError as error:
    raise newException(MatterError, "invalid regex in " & context & ": " & error.msg)

proc hasUnescapedAnchor(source: string, anchor: char): bool =
  var position = 0
  while position + 1 < source.len:
    if source[position] == '\\':
      if source[position + 1] == anchor:
        return true
      position += 2
    else:
      inc position

proc substituteCaptures(source, line: string, matched: Match): string =
  ## Substitute TextMate numeric backreferences with escaped matched text.
  var i = 0
  while i < source.len:
    if source[i] == '\\' and i + 1 < source.len and source[i + 1].isDigit:
      var j = i + 1
      while j < source.len and source[j].isDigit:
        inc j
      let index = parseInt(source[i + 1 ..< j])
      if matched.captured(index):
        let span = matched.captureSpan(index)
        for ch in line[span.a ..< span.b]:
          if ch in
              {'\\', '.', '^', '$', '|', '(', ')', '[', ']', '{', '}', '*', '+', '?'}:
            result.add('\\')
          result.add(ch)
      i = j
    else:
      result.add(source[i])
      inc i

proc dynamicName(source, line: string, matched: Match): string =
  if source.len == 0:
    return ""
  var i = 0
  while i < source.len:
    if source[i] == '$' and i + 1 < source.len and source[i + 1].isDigit:
      var j = i + 1
      while j < source.len and source[j].isDigit:
        inc j
      let index = parseInt(source[i + 1 ..< j])
      if matched.captured(index):
        let span = matched.captureSpan(index)
        var capture = line[span.a ..< span.b]
        while capture.len > 0 and capture[0] == '.':
          capture = capture[1 ..^ 1]
        result.add(capture)
      i = j
    elif source[i] == '$' and i + 3 < source.len and source[i + 1] == '{':
      let close = source.find('}', i + 2)
      if close > i:
        let instruction = source[i + 2 ..< close]
        let colon = instruction.find(":/")
        if colon > 0 and instruction[0 ..< colon].allCharsInSet({'0' .. '9'}):
          let index = parseInt(instruction[0 ..< colon])
          if matched.captured(index):
            let span = matched.captureSpan(index)
            var capture = line[span.a ..< span.b]
            while capture.len > 0 and capture[0] == '.':
              capture = capture[1 ..^ 1]
            case instruction[colon + 2 ..^ 1]
            of "downcase":
              capture = capture.toLowerAscii()
            of "upcase":
              capture = capture.toUpperAscii()
            else:
              discard
            result.add(capture)
            i = close + 1
            continue
      result.add(source[i])
      inc i
    else:
      result.add(source[i])
      inc i

proc start*(token: Token): int {.inline.} =
  ## Compatibility accessor for ``startIndex``.
  token.startIndex

proc stop*(token: Token): int {.inline.} =
  ## Compatibility accessor for ``endIndex``.
  token.endIndex

proc state*(lineResult: TokenizeLineResult): StateStack {.inline.} =
  ## Compatibility accessor for ``ruleStack``.
  lineResult.ruleStack

proc depth*(stack: StateStack): int =
  ## Return the immutable stack depth; the root frame has depth one.
  var frame = stack
  while not frame.isNil:
    inc result
    frame = frame.parent

proc `==`*(a, b: StateStack): bool =
  if a.isNil or b.isNil:
    return a.isNil and b.isNil
  a.rule == b.rule and a.nameScopes == b.nameScopes and a.scopes == b.scopes and
    a.hasEndRegex == b.hasEndRegex and
    (not a.hasEndRegex or a.endRegex.pattern == b.endRegex.pattern) and
    a.isRoot == b.isRoot and a.isFirstLine == b.isFirstLine and a.parent == b.parent

proc copyScopes(scopes: seq[string]): seq[string] =
  result = newSeqOfCap[string](scopes.len)
  for scope in scopes:
    if scope.len > 0:
      result.add(scope)

proc compileCaptures(
  grammar: RawGrammar,
  repository: RawRepository,
  base: RawRule,
  raw: RawCaptures,
  cache: var Table[pointer, CompiledRule],
  registry: Registry,
): OrderedTable[int, CompiledCapture]

proc compileRule(
  grammar: RawGrammar,
  repository: RawRepository,
  base: RawRule,
  raw: RawRule,
  cache: var Table[pointer, CompiledRule],
  registry: Registry,
): CompiledRule

proc mergedRepository(parent, child: RawRepository): RawRepository =
  result = initOrderedTable[string, RawRule]()
  for key, value in parent:
    result[key] = value
  for key, value in child:
    result[key] = value

proc compilePatterns(
    grammar: RawGrammar,
    repository: RawRepository,
    base: RawRule,
    patterns: openArray[RawRule],
    cache: var Table[pointer, CompiledRule],
    registry: Registry,
): seq[CompiledRule] =
  for pattern in patterns:
    if pattern.isNil:
      continue
    if pattern.include.len == 0:
      result.add(compileRule(grammar, repository, base, pattern, cache, registry))
    elif pattern.include == "$self":
      if repository.hasKey("$self"):
        result.add(
          compileRule(grammar, repository, base, repository["$self"], cache, registry)
        )
    elif pattern.include == "$base":
      result.add(compileRule(grammar, repository, base, base, cache, registry))
    elif pattern.include.startsWith("#"):
      let name = pattern.include[1 ..^ 1]
      if repository.hasKey(name):
        result.add(
          compileRule(grammar, repository, base, repository[name], cache, registry)
        )
    else:
      let split = pattern.include.find('#')
      let scope =
        if split < 0:
          pattern.include
        else:
          pattern.include[0 ..< split]
      if not registry.grammars.hasKey(scope):
        raise
          newException(MatterError, "missing grammar for include " & pattern.include)
      let external = registry.grammars[scope]
      let externalRoot =
        RawRule(patterns: external.patterns, repository: external.repository)
      var externalRepo =
        mergedRepository(external.repository, initOrderedTable[string, RawRule]())
      externalRepo["$self"] = externalRoot
      externalRepo["$base"] = base
      if split < 0:
        result.add(
          compileRule(external, externalRepo, base, externalRoot, cache, registry)
        )
      else:
        let name = pattern.include[split + 1 ..^ 1]
        if not externalRepo.hasKey(name):
          raise newException(MatterError, "missing repository rule " & pattern.include)
        result.add(
          compileRule(external, externalRepo, base, externalRepo[name], cache, registry)
        )

proc compileCaptures(
    grammar: RawGrammar,
    repository: RawRepository,
    base: RawRule,
    raw: RawCaptures,
    cache: var Table[pointer, CompiledRule],
    registry: Registry,
): OrderedTable[int, CompiledCapture] =
  result = initOrderedTable[int, CompiledCapture]()
  for index, capture in raw:
    var nested: CompiledRule
    if capture.patterns.len > 0 or capture.include.len > 0:
      nested = compileRule(grammar, repository, base, capture, cache, registry)
    result[index] = CompiledCapture(
      name: capture.name, contentName: capture.contentName, rule: nested
    )

proc compileRule(
    grammar: RawGrammar,
    repository: RawRepository,
    base: RawRule,
    raw: RawRule,
    cache: var Table[pointer, CompiledRule],
    registry: Registry,
): CompiledRule =
  if raw.isNil:
    raise newException(MatterError, "nil grammar rule")
  let key = cast[pointer](raw)
  if cache.hasKey(key):
    return cache[key]
  result = CompiledRule(name: raw.name, contentName: raw.contentName)
  cache[key] = result
  let localRepository = mergedRepository(repository, raw.repository)
  if raw.match.len > 0:
    result.kind = rkMatch
    result.matchSource = raw.match
    result.matchRegex = regexFor(raw.match, grammar.scopeName & " match")
    result.captures =
      compileCaptures(grammar, localRepository, base, raw.captures, cache, registry)
  elif raw.begin.len > 0:
    result.beginSource = raw.begin
    result.beginRegex = regexFor(raw.begin, grammar.scopeName & " begin")
    result.patterns =
      compilePatterns(grammar, localRepository, base, raw.patterns, cache, registry)
    result.beginCaptures = compileCaptures(
      grammar,
      localRepository,
      base,
      if raw.hasBeginCaptures: raw.beginCaptures else: raw.captures,
      cache,
      registry,
    )
    if raw.while.len > 0:
      result.kind = rkBeginWhile
      result.whileSource = raw.while
      result.whileCaptures = compileCaptures(
        grammar,
        localRepository,
        base,
        if raw.hasWhileCaptures: raw.whileCaptures else: raw.captures,
        cache,
        registry,
      )
    else:
      result.kind = rkBeginEnd
      result.endSource = raw.end
      result.applyEndPatternLast = raw.applyEndPatternLast
      result.endCaptures = compileCaptures(
        grammar,
        localRepository,
        base,
        if raw.hasEndCaptures: raw.endCaptures else: raw.captures,
        cache,
        registry,
      )
  else:
    result.kind = rkInclude
    result.patterns =
      compilePatterns(grammar, localRepository, base, raw.patterns, cache, registry)

proc loadGrammar*(registry: Registry, scopeName: string): Grammar =
  ## Compile a registered grammar by scope name.
  if not registry.grammars.hasKey(scopeName):
    raise newException(MatterError, "no grammar registered for " & scopeName)
  let raw = registry.grammars[scopeName]
  let rootRaw = RawRule(patterns: raw.patterns, repository: raw.repository)
  var repository = raw.repository
  repository["$self"] = rootRaw
  repository["$base"] = rootRaw
  var cache = initTable[pointer, CompiledRule]()
  result = Grammar(
    scopeName: scopeName,
    root: compileRule(raw, repository, rootRaw, rootRaw, cache, registry),
  )
  var injectionNames = registry.injectionScopes.getOrDefault(scopeName)
  for name in registry.grammars.keys:
    let candidate = registry.grammars[name]
    if candidate.injectionSelector.len > 0 and name notin injectionNames:
      injectionNames.add(name)
  for name in injectionNames:
    if registry.grammars.hasKey(name):
      let injectionGrammar = registry.grammars[name]
      for selector in parseScopeSelectors(injectionGrammar.injectionSelector):
        let injectionRoot = RawRule(
          patterns: injectionGrammar.patterns, repository: injectionGrammar.repository
        )
        var injectionRepo = injectionGrammar.repository
        injectionRepo["$self"] = injectionRoot
        injectionRepo["$base"] = rootRaw
        var injectionCache = initTable[pointer, CompiledRule]()
        result.injections.add(
          Injection(
            selector: selector,
            rule: compileRule(
              injectionGrammar, injectionRepo, rootRaw, injectionRoot, injectionCache,
              registry,
            ),
          )
        )
  for selector, injection in raw.injections:
    for parsed in parseScopeSelectors(selector):
      result.injections.add(
        Injection(
          selector: parsed,
          rule: compileRule(raw, repository, rootRaw, injection, cache, registry),
        )
      )
  result.injections.sort(
    proc(a, b: Injection): int =
      cmp(ord(a.selector.priority), ord(b.selector.priority))
  )

proc newState(
    rule: CompiledRule,
    parent: StateStack,
    nameScopes: seq[string],
    scopes: seq[string],
    enterPos, anchorPos: int,
    isRoot = false,
    isFirstLine = false,
    beginRuleCapturedEol = false,
): StateStack =
  StateStack(
    parent: parent,
    rule: rule,
    nameScopes: nameScopes,
    scopes: scopes,
    enterPos: enterPos,
    anchorPos: anchorPos,
    isRoot: isRoot,
    isFirstLine: isFirstLine,
    beginRuleCapturedEol: beginRuleCapturedEol,
  )

proc initialState(grammar: Grammar): StateStack =
  let scopes = @[grammar.scopeName]
  newState(grammar.root, nil, scopes, scopes, 0, -1, true, true)

proc nextLineState(stack: StateStack): StateStack =
  StateStack(
    parent:
      if stack.parent.isNil:
        nil
      else:
        nextLineState(stack.parent),
    rule: stack.rule,
    nameScopes: stack.nameScopes,
    scopes: stack.scopes,
    endRegex: stack.endRegex,
    hasEndRegex: stack.hasEndRegex,
    enterPos: -1,
    anchorPos: if stack.beginRuleCapturedEol: 0 else: -1,
    isRoot: stack.isRoot,
    isFirstLine: false,
    beginRuleCapturedEol: stack.beginRuleCapturedEol,
  )

proc withAnchor(stack: StateStack, anchorPos: int): StateStack =
  StateStack(
    parent: stack.parent,
    rule: stack.rule,
    nameScopes: stack.nameScopes,
    scopes: stack.scopes,
    endRegex: stack.endRegex,
    hasEndRegex: stack.hasEndRegex,
    enterPos: stack.enterPos,
    anchorPos: anchorPos,
    isRoot: stack.isRoot,
    isFirstLine: stack.isFirstLine,
    beginRuleCapturedEol: stack.beginRuleCapturedEol,
  )

proc addToken(
    tokens: var seq[Token], start, stop: int, scopes: seq[string], visibleLength: int
) =
  let boundedStart = min(start, visibleLength)
  let boundedStop = min(stop, visibleLength)
  if boundedStop <= boundedStart:
    return
  if tokens.len > 0 and tokens[^1].endIndex == boundedStart and
      tokens[^1].scopes == scopes:
    tokens[^1].endIndex = boundedStop
  else:
    tokens.add(
      Token(startIndex: boundedStart, endIndex: boundedStop, scopes: copyScopes(scopes))
    )

proc resolvedRegex(source, line: string, matched: Match, context: string): Regex =
  regexFor(substituteCaptures(source, line, matched), context)

proc findRegex(
    source: string,
    regex: Regex,
    line: string,
    position, anchorPos: int,
    isFirstLine: bool,
): Match =
  let disableA = not isFirstLine and source.hasUnescapedAnchor('A')
  let disableG = position != anchorPos and source.hasUnescapedAnchor('G')
  if not (disableA or disableG):
    return searchWithContext(line, regex, position)
  let anchored = regexFor(source, "anchored token", isFirstLine, position == anchorPos)
  searchWithContext(line, anchored, position)

proc findInRule(
    rule: CompiledRule,
    line: string,
    position: int,
    anchorPos: int,
    isFirstLine: bool,
    seen: var HashSet[pointer],
    result: var Candidate,
) =
  let key = cast[pointer](rule)
  if key in seen:
    return
  seen.incl(key)
  case rule.kind
  of rkMatch:
    let m = findRegex(
      rule.matchSource, rule.matchRegex, line, position, anchorPos, isFirstLine
    )
    if m.found:
      result = Candidate(found: true, kind: ckRule, rule: rule, matched: m)
  of rkBeginEnd, rkBeginWhile:
    let m = findRegex(
      rule.beginSource, rule.beginRegex, line, position, anchorPos, isFirstLine
    )
    if m.found:
      result = Candidate(found: true, kind: ckRule, rule: rule, matched: m)
  of rkInclude:
    for child in rule.patterns:
      var candidate: Candidate
      findInRule(child, line, position, anchorPos, isFirstLine, seen, candidate)
      if candidate.found and
          (
            not result.found or
            candidate.matched.matchSpan.a < result.matched.matchSpan.a
          ):
        result = candidate

proc bestRule(
    rule: CompiledRule, line: string, position, anchorPos: int, isFirstLine: bool
): Candidate =
  var seen = initHashSet[pointer]()
  findInRule(rule, line, position, anchorPos, isFirstLine, seen, result)

proc bestChildRule(
    rule: CompiledRule, line: string, position, anchorPos: int, isFirstLine: bool
): Candidate =
  var seen = initHashSet[pointer]()
  for child in rule.patterns:
    var candidate: Candidate
    findInRule(child, line, position, anchorPos, isFirstLine, seen, candidate)
    if candidate.found and
        (not result.found or candidate.matched.matchSpan.a < result.matched.matchSpan.a):
      result = candidate

proc tokenizeInto(
  grammar: Grammar,
  line: string,
  start, finish: int,
  initial: StateStack,
  tokens: var seq[Token],
  visibleLength: int,
): StateStack

proc applyCaptures(
    grammar: Grammar,
    line: string,
    tokens: var seq[Token],
    baseScopes: seq[string],
    captures: OrderedTable[int, CompiledCapture],
    matched: Match,
    visibleLength: int,
) =
  let whole = matched.matchSpan
  var entries: seq[(int, CompiledCapture)]
  for index, capture in captures:
    if matched.captured(index):
      entries.add((index, capture))
  entries.sort(
    proc(a, b: (int, CompiledCapture)): int =
      cmp(a[0], b[0])
  )

  type LocalCapture = object
    endPos: int
    scopes: seq[string]

  var cursor = whole.a
  var localStack: seq[LocalCapture]
  for (index, capture) in entries:
    let span = matched.captureSpan(index)
    if span.a < whole.a or span.b > whole.b or span.a == span.b:
      continue
    while localStack.len > 0 and localStack[^1].endPos <= span.a:
      addToken(
        tokens, cursor, localStack[^1].endPos, localStack[^1].scopes, visibleLength
      )
      cursor = localStack[^1].endPos
      localStack.setLen(localStack.len - 1)
    let parentScopes =
      if localStack.len > 0:
        localStack[^1].scopes
      else:
        baseScopes
    addToken(tokens, cursor, span.a, parentScopes, visibleLength)
    cursor = span.a
    var nameScopes = copyScopes(parentScopes)
    let captureName = dynamicName(capture.name, line, matched)
    if captureName.len > 0:
      nameScopes.add(captureName)
    var contentScopes = copyScopes(nameScopes)
    let contentName = dynamicName(capture.contentName, line, matched)
    if contentName.len > 0:
      contentScopes.add(contentName)
    if not capture.rule.isNil and span.b > span.a:
      discard tokenizeInto(
        grammar,
        line,
        span.a,
        span.b,
        newState(capture.rule, nil, nameScopes, contentScopes, span.a, -1),
        tokens,
        visibleLength,
      )
      cursor = span.b
    else:
      localStack.add(LocalCapture(endPos: span.b, scopes: contentScopes))
  while localStack.len > 0:
    addToken(
      tokens, cursor, localStack[^1].endPos, localStack[^1].scopes, visibleLength
    )
    cursor = localStack[^1].endPos
    localStack.setLen(localStack.len - 1)
  addToken(tokens, cursor, whole.b, baseScopes, visibleLength)

proc checkWhiles(
    grammar: Grammar,
    line: string,
    position: var int,
    stack: StateStack,
    tokens: var seq[Token],
    visibleLength: int,
    isFirstLine: bool,
): StateStack =
  var chain: seq[StateStack]
  var anchorPos = stack.anchorPos
  var node = stack
  while not node.isNil:
    chain.add(node)
    node = node.parent
  for i in countdown(chain.high, 0):
    let frame = chain[i]
    if frame.rule.kind == rkBeginWhile:
      let source =
        if frame.hasEndRegex: frame.endRegex.pattern else: frame.rule.whileSource
      let regex =
        if frame.hasEndRegex:
          frame.endRegex
        else:
          regexFor(source, grammar.scopeName & " while")
      let matched = findRegex(source, regex, line, position, anchorPos, isFirstLine)
      if not matched.found:
        return frame.parent
      let span = matched.matchSpan
      applyCaptures(
        grammar, line, tokens, frame.scopes, frame.rule.whileCaptures, matched,
        visibleLength,
      )
      position = span.b
      anchorPos = span.b
  withAnchor(stack, anchorPos)

proc tokenizeInto(
    grammar: Grammar,
    line: string,
    start, finish: int,
    initial: StateStack,
    tokens: var seq[Token],
    visibleLength: int,
): StateStack =
  var position = start
  var stack = initial
  var scopeStack =
    if stack.isNil:
      @[grammar.scopeName]
    else:
      stack.scopes
  if not stack.isNil:
    stack =
      checkWhiles(grammar, line, position, stack, tokens, visibleLength, start == 0)
    scopeStack =
      if stack.isNil:
        @[grammar.scopeName]
      else:
        stack.scopes
  var zeroWidthAt = -1
  while position <= finish:
    let anchorPos = if stack.isNil: -1 else: stack.anchorPos
    let active = if stack.isNil: grammar.root else: stack.rule
    var candidate =
      if stack.isNil:
        bestRule(active, line, position, anchorPos, start == 0)
      else:
        bestChildRule(active, line, position, anchorPos, start == 0)
    if not stack.isNil and stack.rule.kind == rkBeginEnd:
      let ending = findRegex(
        stack.endRegex.pattern, stack.endRegex, line, position, anchorPos, start == 0
      )
      if ending.found and (
        not candidate.found or ending.matchSpan.a < candidate.matched.matchSpan.a or (
          ending.matchSpan.a == candidate.matched.matchSpan.a and
          not stack.rule.applyEndPatternLast
        )
      ):
        candidate = Candidate(found: true, kind: ckEnd, matched: ending)
    var injectionWon = false
    for injection in grammar.injections:
      if injection.selector.matches(scopeStack):
        let injected = bestRule(injection.rule, line, position, anchorPos, start == 0)
        if injected.found and (
          not candidate.found or
          injected.matched.matchSpan.a < candidate.matched.matchSpan.a or (
            injected.matched.matchSpan.a == candidate.matched.matchSpan.a and
            injection.selector.priority == spLeft and not injectionWon
          )
        ):
          candidate = injected
          injectionWon = true
    if not candidate.found or candidate.matched.matchSpan.a >= finish:
      addToken(tokens, position, finish, scopeStack, visibleLength)
      break
    let span = candidate.matched.matchSpan
    addToken(tokens, position, span.a, scopeStack, visibleLength)
    if candidate.kind == ckEnd:
      let closingScopes = stack.nameScopes
      applyCaptures(
        grammar, line, tokens, closingScopes, stack.rule.endCaptures, candidate.matched,
        visibleLength,
      )
      let old = stack
      stack = stack.parent
      scopeStack =
        if stack.isNil:
          @[grammar.scopeName]
        else:
          stack.scopes
      if span.b == position and old.enterPos == position:
        stack = old
        scopeStack = old.scopes
        addToken(tokens, position, finish, scopeStack, visibleLength)
        break
    else:
      let rule = candidate.rule
      case rule.kind
      of rkMatch:
        var matchScopes = copyScopes(scopeStack)
        let ruleName = dynamicName(rule.name, line, candidate.matched)
        if ruleName.len > 0:
          matchScopes.add(ruleName)
        applyCaptures(
          grammar, line, tokens, matchScopes, rule.captures, candidate.matched,
          visibleLength,
        )
      of rkBeginEnd, rkBeginWhile:
        var openedScopes = copyScopes(scopeStack)
        let ruleName = dynamicName(rule.name, line, candidate.matched)
        if ruleName.len > 0:
          openedScopes.add(ruleName)
        applyCaptures(
          grammar, line, tokens, openedScopes, rule.beginCaptures, candidate.matched,
          visibleLength,
        )
        let nameScopes = copyScopes(openedScopes)
        let contentName = dynamicName(rule.contentName, line, candidate.matched)
        if contentName.len > 0:
          openedScopes.add(contentName)
        let frame = newState(rule, stack, nameScopes, openedScopes, position, span.b)
        if rule.kind == rkBeginEnd:
          frame.hasEndRegex = true
          frame.endRegex = resolvedRegex(
            rule.endSource, line, candidate.matched, grammar.scopeName & " end"
          )
        elif rule.whileSource.contains("\\"):
          frame.hasEndRegex = true
          frame.endRegex = resolvedRegex(
            rule.whileSource, line, candidate.matched, grammar.scopeName & " while"
          )
        stack = frame
        scopeStack = openedScopes
      of rkInclude:
        discard
    if span.b == position:
      if zeroWidthAt == position:
        addToken(tokens, position, finish, scopeStack, visibleLength)
        break
      zeroWidthAt = position
    else:
      position = span.b
      zeroWidthAt = -1
  stack

proc tokenizeLine*(
    grammar: Grammar,
    line: string,
    previousState: StateStack = nil,
    timeLimitMs: int = 0,
): TokenizeLineResult =
  ## Tokenize one line. State frames are never mutated and can be reused safely.
  let started = getMonoTime()
  let scannedLine = line & "\n"
  let lineLength = line.len
  var tokens: seq[Token]
  var position = 0
  var stack =
    if previousState.isNil:
      initialState(grammar)
    else:
      previousState
  let isFirstLine = stack.isFirstLine
  var scopes = stack.scopes
  stack =
    checkWhiles(grammar, scannedLine, position, stack, tokens, lineLength, isFirstLine)
  if stack.isNil:
    stack = initialState(grammar)
  scopes = stack.scopes
  var zeroWidthAt = -1
  while position <= lineLength:
    if timeLimitMs > 0 and (getMonoTime() - started).inMilliseconds > timeLimitMs:
      addToken(tokens, position, lineLength, scopes, lineLength)
      return TokenizeLineResult(tokens: tokens, ruleStack: stack, stoppedEarly: true)
    let anchorPos = stack.anchorPos
    var candidate =
      if stack.isRoot:
        bestRule(stack.rule, scannedLine, position, anchorPos, isFirstLine)
      else:
        bestChildRule(stack.rule, scannedLine, position, anchorPos, isFirstLine)
    if stack.rule.kind == rkBeginEnd:
      let ending = findRegex(
        stack.endRegex.pattern, stack.endRegex, scannedLine, position, anchorPos,
        isFirstLine,
      )
      if ending.found and (
        not candidate.found or ending.matchSpan.a < candidate.matched.matchSpan.a or (
          ending.matchSpan.a == candidate.matched.matchSpan.a and
          not stack.rule.applyEndPatternLast
        )
      ):
        candidate = Candidate(found: true, kind: ckEnd, matched: ending)
    var injectionWon = false
    for injection in grammar.injections:
      if injection.selector.matches(scopes):
        let injected =
          bestRule(injection.rule, scannedLine, position, anchorPos, isFirstLine)
        if injected.found and (
          not candidate.found or
          injected.matched.matchSpan.a < candidate.matched.matchSpan.a or (
            injected.matched.matchSpan.a == candidate.matched.matchSpan.a and
            injection.selector.priority == spLeft and not injectionWon
          )
        ):
          candidate = injected
          injectionWon = true
    if not candidate.found:
      addToken(tokens, position, lineLength, scopes, lineLength)
      position = lineLength + 1
    else:
      let span = candidate.matched.matchSpan
      addToken(tokens, position, span.a, scopes, lineLength)
      if candidate.kind == ckEnd:
        let closingScopes = stack.nameScopes
        applyCaptures(
          grammar, scannedLine, tokens, closingScopes, stack.rule.endCaptures,
          candidate.matched, lineLength,
        )
        let old = stack
        stack = stack.parent
        if stack.isNil:
          stack = initialState(grammar)
        scopes = stack.scopes
        if span.b == position and old.enterPos == position:
          stack = old
          scopes = old.scopes
          addToken(tokens, position, lineLength, scopes, lineLength)
          position = lineLength + 1
      else:
        let rule = candidate.rule
        case rule.kind
        of rkMatch:
          var matchScopes = copyScopes(scopes)
          let ruleName = dynamicName(rule.name, scannedLine, candidate.matched)
          if ruleName.len > 0:
            matchScopes.add(ruleName)
          applyCaptures(
            grammar, scannedLine, tokens, matchScopes, rule.captures, candidate.matched,
            lineLength,
          )
        of rkBeginEnd, rkBeginWhile:
          var opened = copyScopes(scopes)
          let ruleName = dynamicName(rule.name, scannedLine, candidate.matched)
          if ruleName.len > 0:
            opened.add(ruleName)
          applyCaptures(
            grammar, scannedLine, tokens, opened, rule.beginCaptures, candidate.matched,
            lineLength,
          )
          let nameScopes = copyScopes(opened)
          let contentName =
            dynamicName(rule.contentName, scannedLine, candidate.matched)
          if contentName.len > 0:
            opened.add(contentName)
          let frame = newState(
            rule,
            stack,
            nameScopes,
            opened,
            position,
            span.b,
            beginRuleCapturedEol = span.b == scannedLine.len,
          )
          if rule.kind == rkBeginEnd:
            frame.hasEndRegex = true
            frame.endRegex = resolvedRegex(
              rule.endSource, scannedLine, candidate.matched, grammar.scopeName & " end"
            )
          elif rule.whileSource.contains("\\"):
            frame.hasEndRegex = true
            frame.endRegex = resolvedRegex(
              rule.whileSource,
              scannedLine,
              candidate.matched,
              grammar.scopeName & " while",
            )
          stack = frame
          scopes = opened
        of rkInclude:
          discard
        if span.b == position and zeroWidthAt == position:
          addToken(tokens, position, lineLength, scopes, lineLength)
          position = lineLength + 1
        else:
          zeroWidthAt = if span.b == position: position else: -1
      if span.b > position:
        position = span.b
  TokenizeLineResult(tokens: tokens, ruleStack: nextLineState(stack))
