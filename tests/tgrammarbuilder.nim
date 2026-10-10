import std/[json, os, osproc, strtabs, strutils, tempfiles, unittest]

import zippy/ziparchives

const repositoryRoot = currentSourcePath.parentDir.parentDir

type GrammarFixture = object
  root, source, archive, catalog, formatterLog: string
  environment: StringTableRef

proc newFixture(): GrammarFixture =
  let root = createTempDir("matter-local-grammar-", "")
  let source = root / "grammars/example"
  let binaries = root / "bin"
  let formatterLog = root / "formatter.log"
  createDir(source)
  createDir(binaries)
  createDir(root / "src/matter")
  createDir(root / "tools")
  copyFile(
    repositoryRoot / "tools/regenerate_grammars.py",
    root / "tools/regenerate_grammars.py",
  )
  writeFile(source / "LICENSE", "Example license\n")
  writeFile(source / "package.json", """{"name":"example"}""")
  writeFile(
    source / "example.tmLanguage.json",
    """{"scopeName":"source.example","patterns":[]}""",
  )
  let package =
    %*{
      "constName": "examplePackage",
      "namespace": "matter",
      "name": "example",
      "version": "1.0.0",
      "sourceKind": "local",
      "sourceRoot": "grammars/example",
      "licenseId": "MIT",
      "licenseUrl": "https://example.com/LICENSE",
      "repositoryUrl": "https://example.com/grammar",
      "downloadUrl": "",
      "specificationUrl": "https://example.com/spec",
      "grammars": [
        [
          "exampleGrammar", "Example", "example", "source.example",
          "./example.tmLanguage.json", true,
        ]
      ],
    }
  let manifest =
    %*{
      "archiveFormat": "matter-textmate-grammar-archive-v1",
      "moeSourceCommit": "example",
      "moeMappings": [],
      "sourceVsixSha256": {},
      "sourceArchiveSha256": {},
      "packages": [package],
    }
  writeFile(root / "tools/grammar_manifest.json", $manifest)

  # Record formatter calls without requiring nph in the test environment.
  when defined(windows):
    writeFile(
      binaries / "nph.bat", "@echo off\r\necho %~1>> \"" & formatterLog & "\"\r\n"
    )
  else:
    let formatter = binaries / "nph"
    writeFile(
      formatter,
      "#!/bin/sh\nprintf '%s\\n' \"$1\" >> " & quoteShell(formatterLog) & "\n",
    )
    setFilePermissions(formatter, {fpUserRead, fpUserWrite, fpUserExec})

  let environment = newStringTable()
  for key, value in envPairs():
    environment[key] = value
  environment["PATH"] = binaries & PathSep & getEnv("PATH")
  GrammarFixture(
    root: root,
    source: source,
    archive: root / "data/grammars/matter-example-1.0.0.zip",
    catalog: root / "data/grammars/catalog.json",
    formatterLog: formatterLog,
    environment: environment,
  )

proc runBuilder(
    fixture: GrammarFixture, arguments = ""
): tuple[output: string, exitCode: int] =
  execCmdEx(
    "python3 -B " & quoteShell(fixture.root / "tools/regenerate_grammars.py") & arguments,
    env = fixture.environment,
  )

suite "local grammar builder":
  test "regeneration is offline and reproducible":
    let fixture = newFixture()
    defer:
      removeDir(fixture.root)
    let first = fixture.runBuilder()
    checkpoint(first.output)
    require first.exitCode == 0
    check "download " notin first.output
    let archiveContents = readFile(fixture.archive)
    let catalogContents = readFile(fixture.catalog)
    check sameFile(
      readFile(fixture.formatterLog).strip,
      fixture.root / "src/matter/grammarpackages.nim",
    )
    let second = fixture.runBuilder()
    checkpoint(second.output)
    require second.exitCode == 0
    check readFile(fixture.archive) == archiveContents
    check readFile(fixture.catalog) == catalogContents
    check readFile(fixture.formatterLog).strip.splitLines.len == 2

    let verified = fixture.runBuilder(" --verify")
    checkpoint(verified.output)
    check verified.exitCode == 0
    check "verified 1 archives" in verified.output
    let package = parseJson(catalogContents)["packages"][0]
    check package["provenance"]["specificationUrl"].getStr == "https://example.com/spec"
    check package["downloadUrl"].getStr == ""
    check readFile(fixture.root / "src/matter/grammarpackages.nim").contains(
      "sourceArchiveSha256: \"\""
    )
    let archive = openZipArchive(fixture.archive)
    defer:
      archive.close()
    check archive.extractFile("LICENSE") == readFile(fixture.source / "LICENSE")
    check archive.extractFile("package.json") ==
      readFile(fixture.source / "package.json")
    check archive.extractFile("grammar/example.tmLanguage.json") ==
      readFile(fixture.source / "example.tmLanguage.json")

  test "verifier rejects a changed local grammar":
    let fixture = newFixture()
    defer:
      removeDir(fixture.root)
    let built = fixture.runBuilder()
    checkpoint(built.output)
    require built.exitCode == 0
    writeFile(
      fixture.source / "example.tmLanguage.json",
      """{"scopeName":"source.example","patterns":[{"match":"x"}]}""",
    )
    let verified = fixture.runBuilder(" --verify")
    checkpoint(verified.output)
    check verified.exitCode != 0
    check "local source differs from archive" in verified.output

  test "verifier rejects changed attribution":
    let fixture = newFixture()
    defer:
      removeDir(fixture.root)
    let built = fixture.runBuilder()
    checkpoint(built.output)
    require built.exitCode == 0
    writeFile(fixture.source / "LICENSE", "Changed license\n")
    let verified = fixture.runBuilder(" --verify")
    checkpoint(verified.output)
    check verified.exitCode != 0
    check "local source differs from archive" in verified.output
