import std/[os, tables, unittest]

import matter

const localHeader = "PK\x03\x04"

func littleEndian16(contents: string, offset: int): int =
  ord(contents[offset]) or (ord(contents[offset + 1]) shl 8)

func littleEndian32(contents: string, offset: int): int =
  ord(contents[offset]) or (ord(contents[offset + 1]) shl 8) or
    (ord(contents[offset + 2]) shl 16) or (ord(contents[offset + 3]) shl 24)

proc readStoredZip(path: string): Table[string, string] =
  ## Reads the deliberately ZIP_STORED grammar archives without a ZIP dependency.
  let contents = readFile(path)
  var offset = 0
  while offset + 30 <= contents.len and contents[offset ..< offset + 4] == localHeader:
    let flags = littleEndian16(contents, offset + 6)
    let compression = littleEndian16(contents, offset + 8)
    let compressedSize = littleEndian32(contents, offset + 18)
    let nameSize = littleEndian16(contents, offset + 26)
    let extraSize = littleEndian16(contents, offset + 28)
    check flags == 0
    check compression == 0
    let nameStart = offset + 30
    let dataStart = nameStart + nameSize + extraSize
    let dataEnd = dataStart + compressedSize
    check dataEnd <= contents.len
    result[contents[nameStart ..< nameStart + nameSize]] =
      contents[dataStart ..< dataEnd]
    offset = dataEnd

suite "bundled grammar archives":
  test "contain attribution and every catalogued grammar parses with Matter":
    let root = currentSourcePath.parentDir.parentDir
    var archives = initTable[string, Table[string, string]]()
    for package in knownPackages:
      let path = root / package.dataArchivePath
      check fileExists(path)
      archives[package.dataArchivePath] = readStoredZip(path)
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
