import std/[os, tables, unittest]

import matter
import zippy/ziparchives

proc readZip(path: string): Table[string, string] =
  ## Read every member through Zippy, including its CRC verification.
  let archive = openZipArchive(path)
  try:
    for member in archive.walkFiles:
      result[member] = archive.extractFile(member)
  finally:
    archive.close()

suite "bundled grammar archives":
  test "contain attribution and every catalogued grammar parses with Matter":
    let root = currentSourcePath.parentDir.parentDir
    var archives = initTable[string, Table[string, string]]()
    for package in knownPackages:
      let path = root / package.dataArchivePath
      check fileExists(path)
      archives[package.dataArchivePath] = readZip(path)
      check archives[package.dataArchivePath].hasKey("LICENSE")
      check archives[package.dataArchivePath].hasKey("package.json")
      check archives[package.dataArchivePath].hasKey("PROVENANCE.json")
    for contribution in knownGrammars:
      let archive = archives[contribution.dataArchivePath]
      check archive.hasKey(contribution.archiveMember)
      if archive.hasKey(contribution.archiveMember):
        let raw = parseRawGrammar(
          archive[contribution.archiveMember], contribution.archiveMember
        )
        check raw.scopeName == contribution.scopeName
