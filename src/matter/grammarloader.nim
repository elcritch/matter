## Optional grammar-package loading for archive, filesystem, and embedded resources.
##
## This module deliberately stays outside Matter's core tokenizer. Applications
## supply a resource callback, so embedded resources do not require filesystem
## access; `zipResourceSource` is a convenience adapter for bundled archives.

import std/[options, os, sets, tables]

import zippy/ziparchives

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

  ZipSource = ref object
    baseDirectory: string
    archives: Table[string, Table[string, string]]

proc extractZipMember(path, member: string): Option[string] =
  var archive: ZipArchiveReader
  try:
    archive = openZipArchive(path)
    for archiveMember in archive.walkFiles:
      if archiveMember == member:
        return some(archive.extractFile(member))
  except CatchableError as error:
    raise newException(
      MatterError, "cannot read grammar archive " & path & ": " & error.msg
    )
  finally:
    if not archive.isNil:
      try:
        archive.close()
      except CatchableError as error:
        raise newException(
          MatterError, "cannot close grammar archive " & path & ": " & error.msg
        )

proc zipResourceSource*(baseDirectory = "."): GrammarResourceSource =
  ## Return a callback that reads and caches members from standard ZIP archives.
  ##
  ## `baseDirectory` contains the catalog's relative `dataArchivePath` files.
  ## The callback caches extracted members after their first successful read.
  let source = ZipSource(
    baseDirectory: baseDirectory, archives: initTable[string, Table[string, string]]()
  )
  result = proc(contribution: GrammarContribution): Option[string] =
    let archivePath = source.baseDirectory / contribution.dataArchivePath
    if source.archives.hasKey(archivePath) and
        source.archives[archivePath].hasKey(contribution.archiveMember):
      return some(source.archives[archivePath][contribution.archiveMember])
    if not fileExists(archivePath):
      return none(string)
    let member = extractZipMember(archivePath, contribution.archiveMember)
    if member.isSome:
      source.archives.mgetOrPut(archivePath, initTable[string, string]())[
        contribution.archiveMember
      ] = member.get
    member

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
