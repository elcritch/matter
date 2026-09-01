import std/[json, options, strutils, unittest]

import matter

const catalogContents = staticRead("../data/grammars/catalog.json")
let catalog = parseJson(catalogContents)

suite "grammar release asset metadata":
  test "embeds every packaged ZIP from the generated catalog":
    check grammarReleaseAssets.len == catalog["packages"].len
    for package in catalog["packages"]:
      let packageKey = package["namespace"].getStr() & "." & package["name"].getStr()
      let asset = findGrammarReleaseAsset(packageKey)
      check asset.isSome
      if asset.isSome:
        let archivePath = package["dataArchivePath"].getStr()
        check asset.get.packageKey == packageKey
        check asset.get.version == package["version"].getStr()
        check asset.get.assetName == archivePath.rsplit('/', maxsplit = 1)[^1]
        check asset.get.archiveSha256 == package["archiveSha256"].getStr()
        check asset.get.upstreamVsixUrl() == package["downloadUrl"].getStr()
        check asset.get.archiveSha256.len == 64
    check findGrammarReleaseAsset("missing.grammar").isNone

  test "forms exact release latest release and pinned upstream URLs":
    let asset = findGrammarReleaseAsset("vscode.cpp").get
    check asset.githubReleaseAssetUrl("v0.2.1") ==
      "https://github.com/elcritch/matter/releases/download/v0.2.1/vscode-cpp-1.95.3.zip"
    check asset.githubLatestReleaseAssetUrl() ==
      "https://github.com/elcritch/matter/releases/latest/download/vscode-cpp-1.95.3.zip"
    check asset.downloadUrl(MatterRelease, "v0.2.1") ==
      asset.githubReleaseAssetUrl("v0.2.1")
    check asset.downloadUrl(MatterRelease) == asset.githubLatestReleaseAssetUrl()
    check asset.downloadUrl(Upstream) == asset.upstreamVsixUrl()

  test "escapes GitHub release URL path segments":
    let asset = GrammarReleaseAsset(assetName: "grammar file#1.zip")
    check asset.githubReleaseAssetUrl("release/one two?#") ==
      "https://github.com/elcritch/matter/releases/download/release%2Fone%20two%3F%23/" &
      "grammar%20file%231.zip"
    check asset.githubLatestReleaseAssetUrl() ==
      "https://github.com/elcritch/matter/releases/latest/download/grammar%20file%231.zip"
