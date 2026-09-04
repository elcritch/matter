## Compilation and incremental tokenization for TextMate grammars.

import std/[algorithm, monotimes, options, sets, strutils, tables, times]

import pkg/reni

import ./[metadata, rawgrammar, selectors, theme]

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

  EmbeddedLanguage* = object
    ## An ordered mapping from a scope-name prefix to a binary language ID.
    scopeName*: string
    languageId*: uint32

  TokenTypeOverride* = object
    ## An ordered selector override for the standard token-type metadata bits.
    selector*: string
    tokenType*: StandardTokenType

  GrammarConfiguration* = object
    ## Optional binary-token metadata configuration for a loaded grammar.
    ##
    ## Mapping and override sequences are intentionally ordered: later
    ## token-type overrides win, while the longest embedded-language scope
    ## prefix wins (retaining sequence order for an equal-length tie).
    initialLanguageId*: uint32
    embeddedLanguages*: seq[EmbeddedLanguage]
    tokenTypes*: seq[TokenTypeOverride]
    balancedBracketSelectors*: seq[string]
    unbalancedBracketSelectors*: seq[string]

  CompiledTokenTypeOverride = object
    selector: ScopeSelector
    tokenType: StandardTokenType

  CompiledGrammarConfiguration = object
    initialLanguageId: uint32
    embeddedLanguages: seq[EmbeddedLanguage]
    tokenTypes: seq[CompiledTokenTypeOverride]
    balancedBracketSelectors, unbalancedBracketSelectors: seq[ScopeSelector]
    balancedBracketAll: bool

  FontInfo* = object ## A UTF-8 byte range with the resolved non-color font settings.
    startIndex*, endIndex*: int
    fontFamily*: string
    fontSizeMultiplier*, lineHeightMultiplier*: float

  Registry* = ref object
    grammars: OrderedTable[string, RawGrammar]
    injectionScopes: Table[string, seq[string]]
    theme: Theme

  Grammar* = ref object
    scopeName: string
    root: CompiledRule
    injections: seq[Injection]
    registry: Registry
    configuration: CompiledGrammarConfiguration

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

  StateStackFrame* = object
    ## An opaque immutable frame snapshot used to transport state-stack diffs.
    rule: CompiledRule
    nameScopes, scopes: seq[string]
    endRegex: Regex
    hasEndRegex: bool
    enterPos, anchorPos: int
    isRoot, isFirstLine, beginRuleCapturedEol: bool

  StackDiff* = object
    ## A physical-identity diff: pop ``pops`` frames, then push ``newFrames``.
    pops*: int
    newFrames*: seq[StateStackFrame]

  Token* = object
    ## A half-open UTF-8 byte range with the active outer-to-inner scope path.
    startIndex*, endIndex*: int
    scopes*: seq[string]

  TokenizeLineResult* = object
    tokens*: seq[Token]
    ruleStack*: StateStack
    stoppedEarly*: bool
    fonts*: seq[FontInfo]

  TokenizeLineResult2* = object
    ## Binary TextMate tokens as alternating UTF-8 start offsets and metadata.
    tokens*: seq[uint32]
    ruleStack*: StateStack
    stoppedEarly*: bool
    fonts*: seq[FontInfo]

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
  try:
    discard searchIntoCtx(matchContext, subject, regex, result, start)
  except RegexLimitError as error:
    raise newException(MatterError, "regex matching limit exceeded: " & error.msg)

proc newRegistry*(): Registry =
  ## Create an empty grammar registry with the default TextMate theme.
  Registry(
    grammars: initOrderedTable[string, RawGrammar](),
    injectionScopes: initTable[string, seq[string]](),
    theme: newTheme(RawTheme()),
  )

proc setTheme*(registry: Registry, rawTheme: RawTheme) =
  ## Replace the registry theme with a newly resolved raw TextMate theme.
  registry.theme = newTheme(rawTheme)

proc setTheme*(registry: Registry, newTheme: Theme) =
  ## Replace the registry theme with an already resolved theme.
  if newTheme.isNil:
    raise newException(MatterError, "theme must not be nil")
  registry.theme = newTheme

proc colorMap*(registry: Registry): seq[string] =
  ## Return a defensive copy of the registry theme's color map.
  registry.theme.colorMap()

proc compileConfiguration(
    configuration: GrammarConfiguration
): CompiledGrammarConfiguration =
  result.initialLanguageId = configuration.initialLanguageId
  result.embeddedLanguages = configuration.embeddedLanguages
  for override in configuration.tokenTypes:
    for selector in parseScopeSelectors(override.selector):
      result.tokenTypes.add(
        CompiledTokenTypeOverride(selector: selector, tokenType: override.tokenType)
      )
  for source in configuration.balancedBracketSelectors:
    if source.strip() == "*":
      result.balancedBracketAll = true
    else:
      for selector in parseScopeSelectors(source):
        result.balancedBracketSelectors.add(selector)
  for source in configuration.unbalancedBracketSelectors:
    for selector in parseScopeSelectors(source):
      result.unbalancedBracketSelectors.add(selector)

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

proc completedRuleStack*(lineResult: TokenizeLineResult): StateStack =
  ## Return a next-line state, rejecting an interrupted tokenization result.
  ##
  ## A result with `stoppedEarly` has a partial `ruleStack` at the point where
  ## its deadline expired. It has not been normalized for the next line and
  ## must not be used as a next-line state.
  if lineResult.stoppedEarly:
    raise
      newException(MatterError, "interrupted tokenization has no completed rule stack")
  lineResult.ruleStack

proc completedRuleStack*(lineResult: TokenizeLineResult2): StateStack =
  ## Return a next-line state, rejecting an interrupted binary-token result.
  if lineResult.stoppedEarly:
    raise
      newException(MatterError, "interrupted tokenization has no completed rule stack")
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
    a.enterPos == b.enterPos and a.anchorPos == b.anchorPos and a.isRoot == b.isRoot and
    a.isFirstLine == b.isFirstLine and a.beginRuleCapturedEol == b.beginRuleCapturedEol and
    a.parent == b.parent

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
      if registry.grammars.hasKey(scope):
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
          if externalRepo.hasKey(name):
            result.add(
              compileRule(
                external, externalRepo, base, externalRepo[name], cache, registry
              )
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

proc loadGrammar*(
    registry: Registry, scopeName: string, configuration: GrammarConfiguration
): Grammar =
  ## Compile a registered grammar by scope name and metadata configuration.
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
    registry: registry,
    configuration: compileConfiguration(configuration),
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

proc loadGrammar*(registry: Registry, scopeName: string): Grammar =
  ## Compile a registered grammar using the default binary-token configuration.
  registry.loadGrammar(scopeName, GrammarConfiguration())

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

proc toStateStackFrame(stack: StateStack): StateStackFrame =
  StateStackFrame(
    rule: stack.rule,
    nameScopes: stack.nameScopes,
    scopes: stack.scopes,
    endRegex: stack.endRegex,
    hasEndRegex: stack.hasEndRegex,
    enterPos: stack.enterPos,
    anchorPos: stack.anchorPos,
    isRoot: stack.isRoot,
    isFirstLine: stack.isFirstLine,
    beginRuleCapturedEol: stack.beginRuleCapturedEol,
  )

proc diffStateStacksRefEq*(first, second: StateStack): StackDiff =
  ## Diff stacks by physical frame identity, never structural equality.
  var left = first
  var right = second
  var leftDepth = left.depth
  var rightDepth = right.depth
  while cast[pointer](left) != cast[pointer](right):
    if not left.isNil and (right.isNil or leftDepth >= rightDepth):
      inc result.pops
      left = left.parent
      dec leftDepth
    else:
      if right.isNil:
        raise newException(MatterError, "invalid state-stack diff")
      result.newFrames.add(right.toStateStackFrame)
      right = right.parent
      dec rightDepth
  result.newFrames.reverse()

proc applyStateStackDiff*(stack: StateStack, diff: StackDiff): StateStack =
  ## Apply a physical-identity stack diff, validating underflow and bad frames.
  if diff.pops < 0:
    raise newException(MatterError, "state-stack diff has a negative pop count")
  result = stack
  for _ in 0 ..< diff.pops:
    if result.isNil:
      raise newException(MatterError, "state-stack diff pops beyond the root")
    result = result.parent
  for frame in diff.newFrames:
    if frame.rule.isNil:
      raise newException(MatterError, "state-stack diff contains an invalid frame")
    result = StateStack(
      parent: result,
      rule: frame.rule,
      nameScopes: frame.nameScopes,
      scopes: frame.scopes,
      endRegex: frame.endRegex,
      hasEndRegex: frame.hasEndRegex,
      enterPos: frame.enterPos,
      anchorPos: frame.anchorPos,
      isRoot: frame.isRoot,
      isFirstLine: frame.isFirstLine,
      beginRuleCapturedEol: frame.beginRuleCapturedEol,
    )

proc tokenizeLine*(
  grammar: Grammar, line: string, previousState: StateStack = nil, timeLimitMs: int = 0
): TokenizeLineResult

proc addToken(
    tokens: var seq[Token], start, stop: int, scopes: seq[string], visibleLength: int
) =
  ## Plain tokens retain every tokenizer emission boundary. `tokenizeLine2`
  ## performs its own metadata coalescing where the reference permits it.
  let boundedStart = min(start, visibleLength)
  let boundedStop = min(stop, visibleLength)
  if boundedStop <= boundedStart:
    return
  tokens.add(
    Token(startIndex: boundedStart, endIndex: boundedStop, scopes: copyScopes(scopes))
  )

proc scopeMatches(scope, prefix: string): bool {.inline.} =
  scope == prefix or
    (scope.len > prefix.len and scope.startsWith(prefix) and scope[prefix.len] == '.')

proc activeScopes*(stack: StateStack): seq[string] =
  ## Return a defensive copy of the active outer-to-inner scope path.
  ##
  ## This is useful when an editor needs the scopes active on an empty line,
  ## where no token carries the current context.
  if not stack.isNil:
    result = copyScopes(stack.scopes)

proc hasActiveScope*(stack: StateStack, scope: string): bool =
  ## Return whether an active scope is `scope` or one of its dotted children.
  if stack.isNil or scope.len == 0:
    return false
  for active in stack.scopes:
    if scopeMatches(active, scope):
      return true

proc firstStandardTokenType(scope: string): OptionalStandardTokenType =
  ## Match vscode-textmate's first word-boundary semantic-type match.
  const names = [
    ("comment", OptionalStandardTokenType.Comment),
    ("string", OptionalStandardTokenType.String),
    ("regex", OptionalStandardTokenType.RegEx),
    ("meta.embedded", OptionalStandardTokenType.Other),
  ]
  result = OptionalStandardTokenType.NotSet
  var first = high(int)
  for (name, tokenType) in names:
    var offset = scope.find(name)
    while offset >= 0:
      let beforeIsWord =
        offset > 0 and (scope[offset - 1].isAlphaNumeric or scope[offset - 1] == '_')
      let after = offset + name.len
      let afterIsWord =
        after < scope.len and (scope[after].isAlphaNumeric or scope[after] == '_')
      if not beforeIsWord and not afterIsWord and offset < first:
        first = offset
        result = tokenType
        break
      offset = scope.find(name, offset + 1)

proc applyStyle(base: var StyleAttributes, update: StyleAttributes) =
  if update.fontStyle != fontStyleNotSet:
    base.fontStyle = update.fontStyle
  if update.foregroundId != 0:
    base.foregroundId = update.foregroundId
  if update.backgroundId != 0:
    base.backgroundId = update.backgroundId
  if update.fontFamily.len > 0:
    base.fontFamily = update.fontFamily
  if update.fontSize != 0:
    base.fontSize = update.fontSize
  if update.lineHeight != 0:
    base.lineHeight = update.lineHeight

proc attributesForScopes(
    grammar: Grammar, scopes: openArray[string]
): tuple[metadata: EncodedTokenAttributes, style: StyleAttributes] =
  let theme = grammar.registry.theme
  result.style = theme.defaults()
  result.metadata = set(
    0'u32,
    grammar.configuration.initialLanguageId,
    OptionalStandardTokenType.NotSet,
    none(bool),
    result.style.fontStyle,
    uint32(result.style.foregroundId),
    uint32(result.style.backgroundId),
  )
  for index, scope in scopes:
    var path = newSeq[string](index + 1)
    for pathIndex in 0 .. index:
      path[pathIndex] = scopes[pathIndex]
    let themed = theme.match(path)
    result.style.applyStyle(themed)
    result.metadata = set(
      result.metadata,
      0,
      firstStandardTokenType(scope),
      none(bool),
      themed.fontStyle,
      uint32(themed.foregroundId),
      uint32(themed.backgroundId),
    )
    var longestEmbeddedScope = -1
    var embeddedLanguageId = 0'u32
    for embedded in grammar.configuration.embeddedLanguages:
      if scopeMatches(scope, embedded.scopeName) and
          embedded.scopeName.len > longestEmbeddedScope:
        longestEmbeddedScope = embedded.scopeName.len
        embeddedLanguageId = embedded.languageId
    if embeddedLanguageId != 0:
      result.metadata = set(
        result.metadata,
        embeddedLanguageId,
        OptionalStandardTokenType.NotSet,
        none(bool),
        fontStyleNotSet,
        0,
        0,
      )
  for override in grammar.configuration.tokenTypes:
    if override.selector.matches(scopes):
      result.metadata = set(
        result.metadata,
        0,
        override.tokenType.toOptionalTokenType(),
        none(bool),
        fontStyleNotSet,
        0,
        0,
      )
  var balanced: Option[bool]
  for selector in grammar.configuration.unbalancedBracketSelectors:
    if selector.matches(scopes):
      balanced = some(false)
      break
  if balanced.isNone:
    if grammar.configuration.balancedBracketAll:
      balanced = some(true)
    else:
      for selector in grammar.configuration.balancedBracketSelectors:
        if selector.matches(scopes):
          balanced = some(true)
          break
  result.metadata = set(
    result.metadata, 0, OptionalStandardTokenType.NotSet, balanced, fontStyleNotSet, 0,
    0,
  )

proc sameFontOptions(a, b: FontInfo): bool {.inline.} =
  a.fontFamily == b.fontFamily and a.fontSizeMultiplier == b.fontSizeMultiplier and
    a.lineHeightMultiplier == b.lineHeightMultiplier

proc addFont(fonts: var seq[FontInfo], start, stop: int, style: StyleAttributes) =
  if stop <= start or
      (style.fontFamily.len == 0 and style.fontSize == 0 and style.lineHeight == 0):
    return
  let font = FontInfo(
    startIndex: start,
    endIndex: stop,
    fontFamily: style.fontFamily,
    fontSizeMultiplier: style.fontSize,
    lineHeightMultiplier: style.lineHeight,
  )
  if fonts.len > 0 and fonts[^1].endIndex == start and fonts[^1].sameFontOptions(font):
    fonts[^1].endIndex = stop
  else:
    fonts.add(font)

proc fontsForTokens(grammar: Grammar, tokens: openArray[Token]): seq[FontInfo] =
  for token in tokens:
    let attributes = grammar.attributesForScopes(token.scopes)
    result.addFont(token.startIndex, token.endIndex, attributes.style)

proc plainResult(
    grammar: Grammar, tokens: seq[Token], ruleStack: StateStack, stoppedEarly = false
): TokenizeLineResult =
  TokenizeLineResult(
    tokens: tokens,
    ruleStack: ruleStack,
    stoppedEarly: stoppedEarly,
    fonts: grammar.fontsForTokens(tokens),
  )

proc containsRtl(line: string): bool =
  ## The reference deliberately disables metadata coalescing for any RTL line.
  var index = 0
  while index < line.len:
    let byte = uint8(line[index])
    var codepoint: int
    var width = 1
    if byte < 0x80:
      codepoint = int(byte)
    elif byte shr 5 == 0x6 and index + 1 < line.len:
      codepoint = (int(byte and 0x1f) shl 6) or (int(uint8(line[index + 1])) and 0x3f)
      width = 2
    elif byte shr 4 == 0xe and index + 2 < line.len:
      codepoint =
        (int(byte and 0x0f) shl 12) or ((int(uint8(line[index + 1])) and 0x3f) shl 6) or
        (int(uint8(line[index + 2])) and 0x3f)
      width = 3
    elif byte shr 3 == 0x1e and index + 3 < line.len:
      codepoint =
        (int(byte and 0x07) shl 18) or ((int(uint8(line[index + 1])) and 0x3f) shl 12) or
        ((int(uint8(line[index + 2])) and 0x3f) shl 6) or
        (int(uint8(line[index + 3])) and 0x3f)
      width = 4
    else:
      codepoint = int(byte)
    if codepoint == 0x05be or codepoint == 0x05c0 or codepoint == 0x05c3 or
        codepoint == 0x05c6 or codepoint == 0x0608 or codepoint == 0x060b or
        codepoint == 0x060d or codepoint == 0x06e5 or codepoint == 0x06e6 or
        codepoint == 0x06ee or codepoint == 0x06ef or codepoint == 0x07b1 or
        codepoint == 0x07f4 or codepoint == 0x07f5 or codepoint == 0x07fa or
        codepoint == 0x081a or codepoint == 0x0824 or codepoint == 0x0828 or
        codepoint == 0x085e or codepoint == 0x088e or codepoint == 0x200f or
        codepoint == 0xfb1d or (codepoint >= 0x05d0 and codepoint <= 0x05f4) or
        (codepoint >= 0x061b and codepoint <= 0x064a) or
        (codepoint >= 0x066d and codepoint <= 0x066f) or
        (codepoint >= 0x0671 and codepoint <= 0x06d5) or
        (codepoint >= 0x06fa and codepoint <= 0x0710) or
        (codepoint >= 0x0712 and codepoint <= 0x072f) or
        (codepoint >= 0x074d and codepoint <= 0x07a5) or codepoint == 0x07ea or
        (codepoint >= 0x07fe and codepoint <= 0x0815) or
        (codepoint >= 0x0830 and codepoint <= 0x0858) or
        (codepoint >= 0x085e and codepoint <= 0x088e) or
        (codepoint >= 0x08a0 and codepoint <= 0x08c9) or
        (codepoint >= 0xfb1f and codepoint <= 0xfb28) or
        (codepoint >= 0xfb2a and codepoint <= 0xfd3d) or
        (codepoint >= 0xfd50 and codepoint <= 0xfdc7) or
        (codepoint >= 0xfdf0 and codepoint <= 0xfdfc) or
        (codepoint >= 0xfe70 and codepoint <= 0xfefc) or
        (codepoint >= 0x10800 and codepoint <= 0x1091b) or
        (codepoint >= 0x10920 and codepoint <= 0x10a00) or
        (codepoint >= 0x10a10 and codepoint <= 0x10a35) or
        (codepoint >= 0x10a40 and codepoint <= 0x10ae4) or
        (codepoint >= 0x10aeb and codepoint <= 0x10b35) or
        (codepoint >= 0x10b40 and codepoint <= 0x10bff) or
        (codepoint >= 0x10c00 and codepoint <= 0x10d23) or
        (codepoint >= 0x10e80 and codepoint <= 0x10ea9) or
        (codepoint >= 0x10ead and codepoint <= 0x10f45) or
        (codepoint >= 0x10f51 and codepoint <= 0x10f81) or
        (codepoint >= 0x10f86 and codepoint <= 0x10ff6) or
        (codepoint >= 0x1e800 and codepoint <= 0x1e8cf) or
        (codepoint >= 0x1e900 and codepoint <= 0x1e943) or
        (codepoint >= 0x1e94b and codepoint <= 0x1ebff) or
        (codepoint >= 0x1ec00 and codepoint <= 0x1eebb):
      return true
    index += width

proc tokenizeLine2*(
    grammar: Grammar,
    line: string,
    previousState: StateStack = nil,
    timeLimitMs: int = 0,
): TokenizeLineResult2 =
  ## Tokenize one line to alternating UTF-8 byte offsets and packed metadata.
  let plain = grammar.tokenizeLine(line, previousState, timeLimitMs)
  let mergeMetadata = not line.containsRtl()
  for token in plain.tokens:
    let metadata = grammar.attributesForScopes(token.scopes).metadata
    if mergeMetadata and result.tokens.len >= 2 and result.tokens[^1] == metadata:
      continue
    result.tokens.add(uint32(token.startIndex))
    result.tokens.add(metadata)
  if result.tokens.len == 0:
    let scopes =
      if plain.ruleStack.isNil:
        @[grammar.scopeName]
      else:
        plain.ruleStack.scopes
    result.tokens = @[0'u32, grammar.attributesForScopes(scopes).metadata]
  result.ruleStack = plain.ruleStack
  result.stoppedEarly = plain.stoppedEarly
  result.fonts = plain.fonts

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
      addToken(tokens, position, span.a, frame.scopes, visibleLength)
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
  ##
  ## When `timeLimitMs` interrupts tokenization, `stoppedEarly` is true and
  ## `ruleStack` is the partial current-line stack, not a valid next-line
  ## state. Retry the line or use `completedRuleStack`, which rejects it.
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
      return plainResult(grammar, tokens, stack, true)
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
  plainResult(grammar, tokens, nextLineState(stack))
