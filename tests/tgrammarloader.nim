import std/[options, os, sequtils, strutils, tables, tempfiles, unittest]

import matter/[engine, grammarloader, grammarpackages]
import zippy/ziparchives

suite "grammar package loader":
  test "resolves cyclic catalog dependencies from an in-memory source":
    let source: GrammarResourceSource = proc(
        contribution: GrammarContribution
    ): Option[string] =
      case contribution.scopeName
      of "source.nim":
        some(
          """{
          "scopeName": "source.nim", "patterns": [
            {"include": "source.nimble"}, {"include": "source.missing"}
          ]
        }"""
        )
      of "source.nimble":
        some(
          """{
          "scopeName": "source.nimble", "patterns": [
            {"include": "source.nim"}, {"include": "source.missing#rule"}
          ]
        }"""
        )
      else:
        none(string)
    let registry = newRegistry()
    let loaded = registry.loadGrammarPackage(source, "source.nim")
    check loaded.loadedScopeNames == @["source.nim", "source.nimble"]
    check loaded.unresolvedIncludes.len == 2
    check loaded.unresolvedIncludes.anyIt(
      it.includingScope == "source.nim" and it.includeSource == "source.missing"
    )
    check loaded.unresolvedIncludes.anyIt(
      it.includingScope == "source.nimble" and it.includeSource == "source.missing#rule"
    )

  test "loads bundled packages and reports optional external dependencies":
    let root = currentSourcePath.parentDir.parentDir
    let registry = newRegistry()
    let loaded =
      registry.loadGrammarPackage(zipResourceSource(root), "text.html.markdown")
    check "text.html.markdown" in loaded.loadedScopeNames
    check loaded.unresolvedIncludes.len > 0
    check loaded.unresolvedIncludes.anyIt(it.includingScope == "text.html.markdown")
    check loaded.unresolvedIncludes.allIt(it.externalScope.len > 0)
    check loaded.unresolvedIncludes.allIt(it.includeSource.len > 0)
    discard registry.loadGrammar("text.html.markdown")

  test "loads support grammars from one bundled archive":
    let root = currentSourcePath.parentDir.parentDir
    let registry = newRegistry()
    let loaded = registry.loadGrammarPackage(zipResourceSource(root), "source.nim")
    check "source.nim" in loaded.loadedScopeNames
    check "source.nimble" in loaded.loadedScopeNames
    discard registry.loadGrammar("source.nim")

  test "loads bundled Terraform source and plan grammars":
    let root = currentSourcePath.parentDir.parentDir

    let terraformRegistry = newRegistry()
    discard terraformRegistry.loadGrammarPackage(
      zipResourceSource(root), "source.hcl.terraform"
    )
    let terraform = terraformRegistry.loadGrammar("source.hcl.terraform")
    let sourceLine = terraform.tokenizeLine("resource \"example\" \"main\" {")
    check sourceLine.tokens.anyIt("source.hcl.terraform" in it.scopes)

    let planRegistry = newRegistry()
    discard planRegistry.loadGrammarPackage(zipResourceSource(root), "source.tofu-plan")
    let plan = planRegistry.loadGrammar("source.tofu-plan")
    let planLine = plan.tokenizeLine("  + name = \"example\"")
    check planLine.tokens.anyIt("markup.inserted.marker.tofu-plan" in it.scopes)

  test "loads contributed injection grammars from a package":
    let root = currentSourcePath.parentDir.parentDir
    let registry = newRegistry()
    let loaded = registry.loadGrammarPackage(zipResourceSource(root), "source.ts")
    check "documentation.injection.ts" in loaded.loadedScopeNames
    discard registry.loadGrammar("source.ts")

  test "bounds one expensive regex in time-limited packaged YAML":
    let root = currentSourcePath.parentDir.parentDir
    let registry = newRegistry()
    discard registry.loadGrammarPackage(zipResourceSource(root), "source.yaml")
    let grammar = registry.loadGrammar("source.yaml")
    var state: StateStack
    for line in [
      "on:", "  push:", "    branches:", "      - main", "  pull_request:",
      "    branches:", "      - '*'", "", "jobs:", "  tests:",
    ]:
      let parsed = grammar.tokenizeLine(line, state)
      check not parsed.stoppedEarly
      state = parsed.completedRuleStack

    let limited = grammar.tokenizeLine(
      "    name: tests (${{ matrix.os }}, ${{ matrix.nimversion }}, " &
        "${{ matrix.display }})",
      state,
      timeLimitMs = 100,
    )
    check limited.stoppedEarly
    check limited.ruleStack == state

  test "packaged YAML block scalars end at a dedented comment or key":
    let root = currentSourcePath.parentDir.parentDir
    let registry = newRegistry()
    discard registry.loadGrammarPackage(zipResourceSource(root), "source.yaml")
    let grammar = registry.loadGrammar("source.yaml")
    for indicator in [">-", "|", ">", "|+"]:
      for dedented in ["  # after scalar", "  steps:"]:
        var state: StateStack
        for line in [
          "jobs:", "  nimargs: " & indicator, "    --opt:none", "", "    -d:Example=96"
        ]:
          let parsed = grammar.tokenizeLine(line, state)
          check not parsed.stoppedEarly
          state = parsed.completedRuleStack
        check state.hasActiveScope("string.unquoted.block.yaml")
        let parsed = grammar.tokenizeLine(dedented, state)
        check not parsed.stoppedEarly
        check not parsed.tokens.anyIt("string.unquoted.block.yaml" in it.scopes)
        if dedented.contains('#'):
          check parsed.tokens.anyIt("comment.line.number-sign.yaml" in it.scopes)
        else:
          check parsed.tokens.anyIt("entity.name.tag.yaml" in it.scopes)

  test "rejects an unavailable requested root resource":
    let unavailable: GrammarResourceSource = proc(
        contribution: GrammarContribution
    ): Option[string] =
      none(string)
    let registry = newRegistry()
    expect MatterError:
      discard registry.loadGrammarPackage(unavailable, "source.nim")

  test "rejects empty and unknown requested roots":
    let source: GrammarResourceSource = proc(
        contribution: GrammarContribution
    ): Option[string] =
      none(string)
    let registry = newRegistry()
    expect MatterError:
      discard registry.loadGrammarPackage(source, "")
    expect MatterError:
      discard registry.loadGrammarPackage(source, "source.not-catalogued")

  test "extracts compressed ZIP members and handles failed reads without caching them":
    let contribution = findGrammar("source.nim").get
    let missingContribution = findGrammar("source.nimble").get
    let (temporaryFile, temporaryPath) = createTempFile("matter-loader-", ".tmp")
    temporaryFile.close()
    removeFile(temporaryPath)
    let temporaryRoot = temporaryPath & ".dir"
    let dataDirectory = temporaryRoot / "data"
    let grammarDirectory = dataDirectory / "grammars"
    createDir(temporaryRoot)
    createDir(dataDirectory)
    createDir(grammarDirectory)
    defer:
      removeFile(grammarDirectory / contribution.dataArchivePath.extractFilename)
      removeDir(grammarDirectory)
      removeDir(dataDirectory)
      removeDir(temporaryRoot)

    let archivePath = temporaryRoot / contribution.dataArchivePath
    let grammar = """{"scopeName": "source.nim", "patterns": []}"""
    var entries = initTable[string, string]()
    entries[contribution.archiveMember] = grammar
    let compressedArchive = createZipArchive(entries)
    writeFile(archivePath, compressedArchive)

    let source = zipResourceSource(temporaryRoot)
    check source(contribution).get == grammar
    check source(missingContribution).isNone
    removeFile(archivePath)
    check source(contribution).get == grammar

    var corruptArchive = compressedArchive
    let centralDirectory = corruptArchive.find("PK\x01\x02")
    check centralDirectory >= 0
    corruptArchive[centralDirectory + 16] =
      char(uint8(corruptArchive[centralDirectory + 16]) xor 1'u8)
    writeFile(archivePath, corruptArchive)
    let retryingSource = zipResourceSource(temporaryRoot)
    try:
      discard retryingSource(contribution)
      check false
    except MatterError as error:
      check error.msg.contains("crc32")

    writeFile(archivePath, compressedArchive)
    check retryingSource(contribution).get == grammar

  test "translates malformed ZIP errors":
    let contribution = findGrammar("source.nim").get
    let (temporaryFile, temporaryPath) = createTempFile("matter-loader-", ".tmp")
    temporaryFile.close()
    removeFile(temporaryPath)
    let temporaryRoot = temporaryPath & ".dir"
    let dataDirectory = temporaryRoot / "data"
    let grammarDirectory = dataDirectory / "grammars"
    createDir(temporaryRoot)
    createDir(dataDirectory)
    createDir(grammarDirectory)
    defer:
      removeFile(grammarDirectory / contribution.dataArchivePath.extractFilename)
      removeDir(grammarDirectory)
      removeDir(dataDirectory)
      removeDir(temporaryRoot)

    writeFile(temporaryRoot / contribution.dataArchivePath, "not a ZIP archive")
    expect MatterError:
      discard zipResourceSource(temporaryRoot)(contribution)
