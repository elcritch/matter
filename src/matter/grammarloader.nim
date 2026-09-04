## Optional grammar-package loading for archive, filesystem, and embedded resources.
##
## This module deliberately stays outside Matter's core tokenizer. Applications
## supply a resource callback, so embedded resources do not require filesystem
## access; `storedZipResourceSource` is a convenience adapter for Matter's
## deliberately ZIP_STORED bundled archives.

import std/[options, os, sets, tables]

import ./[engine, grammarpackages, rawgrammar]

type
  GrammarResourceSource* =
    proc(contribution: GrammarContribution): Option[string] {.closure.}
    ## Returns the text for one catalogued grammar contribution, if available.

  UnresolvedGrammarInclude* = object
    ## An external include that could not be loaded from the supplied resources.
    includingScope*: string
    includeSource*: string
    externalScope*: string

  GrammarPackageLoadResult* = object
    ## The grammars registered by a package load and optional missing includes.
    loadedScopeNames*: seq[string]
    unresolvedIncludes*: seq[UnresolvedGrammarInclude]

  StoredZipSource = ref object
    baseDirectory: string
    archives: Table[string, Table[string, string]]

proc littleEndian16(contents: string, offset: int): int =
  if offset < 0 or offset + 2 > contents.len:
    raise newException(MatterError, "truncated ZIP field")
  ord(contents[offset]) or (ord(contents[offset + 1]) shl 8)

proc littleEndian32(contents: string, offset: int): uint32 =
  if offset < 0 or offset + 4 > contents.len:
    raise newException(MatterError, "truncated ZIP field")
  uint32(ord(contents[offset])) or (uint32(ord(contents[offset + 1])) shl 8) or
    (uint32(ord(contents[offset + 2])) shl 16) or
    (uint32(ord(contents[offset + 3])) shl 24)

proc readStoredZip(path: string): Table[string, string] =
  const localHeader = "PK\x03\x04"
  let contents =
    try:
      readFile(path)
    except CatchableError as error:
      raise newException(
        MatterError, "cannot read grammar archive " & path & ": " & error.msg
      )
  var offset = 0
  var foundLocalMember = false
  while offset + 4 <= contents.len and contents[offset ..< offset + 4] == localHeader:
    foundLocalMember = true
    if offset + 30 > contents.len:
      raise newException(MatterError, "truncated ZIP header in " & path)
    let flags = littleEndian16(contents, offset + 6)
    let compression = littleEndian16(contents, offset + 8)
    let compressedSize = littleEndian32(contents, offset + 18)
    let nameSize = littleEndian16(contents, offset + 26)
    let extraSize = littleEndian16(contents, offset + 28)
    if flags != 0:
      raise newException(MatterError, "ZIP data descriptors are unsupported in " & path)
    if compression != 0:
      raise
        newException(MatterError, "compressed ZIP members are unsupported in " & path)
    let nameStart = offset + 30
    let dataStart = nameStart + nameSize + extraSize
    if nameStart > contents.len or dataStart > contents.len or
        uint64(compressedSize) > uint64(contents.len - dataStart):
      raise newException(MatterError, "truncated ZIP member in " & path)
    let dataEnd = dataStart + int(compressedSize)
    result[contents[nameStart ..< nameStart + nameSize]] =
      contents[dataStart ..< dataEnd]
    offset = dataEnd
  if not foundLocalMember or offset + 4 > contents.len or
      contents[offset ..< offset + 4] != "PK\x01\x02" or contents.len < 22 or
      contents[contents.len - 22 ..< contents.len - 18] != "PK\x05\x06":
    raise newException(MatterError, "truncated or unsupported ZIP structure in " & path)

proc storedZipResourceSource*(baseDirectory = "."): GrammarResourceSource =
  ## Return a callback that reads Matter's uncompressed bundled grammar ZIPs.
  ##
  ## `baseDirectory` contains the catalog's relative `dataArchivePath` files.
  ## The callback caches archive members after their first read.
  let source = StoredZipSource(
    baseDirectory: baseDirectory, archives: initTable[string, Table[string, string]]()
  )
  result = proc(contribution: GrammarContribution): Option[string] =
    let archivePath = source.baseDirectory / contribution.dataArchivePath
    if not source.archives.hasKey(archivePath):
      if not fileExists(archivePath):
        return none(string)
      source.archives[archivePath] = readStoredZip(archivePath)
    let archive = source.archives[archivePath]
    if archive.hasKey(contribution.archiveMember):
      some(archive[contribution.archiveMember])
    else:
      none(string)

proc externalScope(includeSource: string): string =
  if includeSource.len == 0 or includeSource[0] == '#' or includeSource[0] == '$':
    return ""
  let separator = includeSource.find('#')
  if separator < 0:
    includeSource
  else:
    includeSource[0 ..< separator]

proc collectIncludes(
    rule: RawRule, includes: var seq[string], seen: var HashSet[pointer]
) =
  if rule.isNil:
    return
  let key = cast[pointer](rule)
  if key in seen:
    return
  seen.incl(key)
  let scope = rule.`include`.externalScope
  if scope.len > 0:
    includes.add(rule.`include`)
  for child in rule.patterns:
    collectIncludes(child, includes, seen)
  for _, child in rule.repository:
    collectIncludes(child, includes, seen)
  for _, child in rule.captures:
    collectIncludes(child, includes, seen)
  for _, child in rule.beginCaptures:
    collectIncludes(child, includes, seen)
  for _, child in rule.endCaptures:
    collectIncludes(child, includes, seen)
  for _, child in rule.whileCaptures:
    collectIncludes(child, includes, seen)

proc externalIncludes(grammar: RawGrammar): seq[string] =
  var seen = initHashSet[pointer]()
  for rule in grammar.patterns:
    collectIncludes(rule, result, seen)
  for _, rule in grammar.repository:
    collectIncludes(rule, result, seen)
  for _, rule in grammar.injections:
    collectIncludes(rule, result, seen)

proc addUnresolved(
    result: var GrammarPackageLoadResult,
    includingScope, includeSource: string,
    seen: var HashSet[string],
) =
  let scope = includeSource.externalScope
  let key = includingScope & "\x1f" & includeSource
  if scope.len > 0 and key notin seen:
    seen.incl(key)
    result.unresolvedIncludes.add(
      UnresolvedGrammarInclude(
        includingScope: includingScope,
        includeSource: includeSource,
        externalScope: scope,
      )
    )

proc loadGrammarPackage*(
    registry: Registry, source: GrammarResourceSource, rootScopes: openArray[string]
): GrammarPackageLoadResult =
  ## Register requested catalogued grammars and their available external includes.
  ##
  ## A missing resource for a requested root raises `MatterError`. Missing
  ## transitive includes are recorded in `unresolvedIncludes`; many grammars
  ## intentionally reference optional language grammars outside Matter's catalog.
  if source.isNil:
    raise newException(MatterError, "grammar resource source must not be nil")
  if rootScopes.len == 0:
    raise newException(MatterError, "at least one grammar root scope is required")
  var pending: seq[(string, string, string, bool)]
  for scope in rootScopes:
    if scope.len == 0:
      raise newException(MatterError, "grammar root scope must not be empty")
    pending.add((scope, "", scope, true))
  var attempted = initHashSet[string]()
  var missingScopes = initHashSet[string]()
  var unresolved = initHashSet[string]()
  var index = 0
  while index < pending.len:
    let (scope, includingScope, includeSource, required) = pending[index]
    inc index
    if scope in attempted:
      if not required and scope in missingScopes:
        result.addUnresolved(includingScope, includeSource, unresolved)
      continue
    attempted.incl(scope)
    let contribution = findGrammar(scope)
    if contribution.isNone:
      if required:
        raise newException(MatterError, "no bundled grammar for " & scope)
      missingScopes.incl(scope)
      result.addUnresolved(includingScope, includeSource, unresolved)
    else:
      let contents = source(contribution.get)
      if contents.isNone:
        if required:
          raise
            newException(MatterError, "grammar resource is unavailable for " & scope)
        missingScopes.incl(scope)
        result.addUnresolved(includingScope, includeSource, unresolved)
      else:
        let raw = parseRawGrammar(contents.get, contribution.get.archiveMember)
        if raw.scopeName != scope:
          raise newException(
            MatterError, "grammar resource for " & scope & " declares " & raw.scopeName
          )
        registry.addGrammar(raw)
        result.loadedScopeNames.add(scope)
        for support in knownGrammars:
          if support.packageKey == contribution.get.packageKey and
              support.scopeName != scope:
            pending.add((support.scopeName, scope, support.scopeName, false))
        for includeSource in raw.externalIncludes:
          let dependency = includeSource.externalScope
          if dependency.len > 0:
            pending.add((dependency, scope, includeSource, false))

proc loadGrammarPackage*(
    registry: Registry, source: GrammarResourceSource, rootScope: string
): GrammarPackageLoadResult =
  ## Register one requested catalogued grammar and its available dependencies.
  registry.loadGrammarPackage(source, [rootScope])
