## Metadata for downloadable Matter grammar ZIP release assets.
##
## The catalog is embedded at compile time. This module performs no file or
## network I/O at runtime; callers choose a URL and perform any download.

import std/[json, options, strutils, uri]

type
  GrammarReleaseAsset* = object
    ## One bundled grammar ZIP and its pinned upstream VSIX source.
    packageKey*: string
    namespace*: string
    name*: string
    version*: string
    assetName*: string
    archiveSha256*: string
    pinnedVsixUrl*: string

  GrammarDownloadSource* {.pure.} = enum
    ## The location from which a grammar ZIP or its original VSIX is obtained.
    MatterRelease
    Upstream

const
  githubRepository* = "elcritch/matter"
  ## The GitHub repository that publishes Matter grammar release assets.
  githubReleaseDownloadBaseUrl* =
    "https://github.com/" & githubRepository & "/releases/download"
  ## Base URL for a GitHub release selected by tag.
  githubLatestReleaseDownloadBaseUrl* =
    "https://github.com/" & githubRepository & "/releases/latest/download"
  ## Base URL for assets on the latest GitHub release.
  grammarCatalog = staticRead("../../data/grammars/catalog.json")

func assetName(archivePath: string): string =
  archivePath.rsplit('/', maxsplit = 1)[^1]

proc parseGrammarReleaseAssets(): seq[GrammarReleaseAsset] =
  let catalog = parseJson(grammarCatalog)
  for package in catalog["packages"]:
    let archivePath = package["dataArchivePath"].getStr()
    result.add GrammarReleaseAsset(
      packageKey: package["namespace"].getStr() & "." & package["name"].getStr(),
      namespace: package["namespace"].getStr(),
      name: package["name"].getStr(),
      version: package["version"].getStr(),
      assetName: assetName(archivePath),
      archiveSha256: package["archiveSha256"].getStr(),
      pinnedVsixUrl: package["downloadUrl"].getStr(),
    )

let grammarReleaseAssets* = parseGrammarReleaseAssets()
## Every grammar ZIP uploaded with each Matter release.

func githubReleaseAssetUrl*(asset: GrammarReleaseAsset, releaseTag: string): string =
  ## Returns this asset's URL on the exact Matter release identified by `releaseTag`.
  githubReleaseDownloadBaseUrl & "/" & releaseTag.encodeUrl(false) & "/" &
    asset.assetName.encodeUrl(false)

func githubLatestReleaseAssetUrl*(asset: GrammarReleaseAsset): string =
  ## Returns this asset's URL on the latest Matter release.
  githubLatestReleaseDownloadBaseUrl & "/" & asset.assetName.encodeUrl(false)

func upstreamVsixUrl*(asset: GrammarReleaseAsset): string =
  ## Returns the exact pinned upstream VSIX URL from which this asset was built.
  asset.pinnedVsixUrl

func downloadUrl*(
    asset: GrammarReleaseAsset, source: GrammarDownloadSource, releaseTag = ""
): string =
  ## Returns a Matter release ZIP URL or the asset's pinned upstream VSIX URL.
  ## An empty `releaseTag` selects the latest Matter release.
  case source
  of MatterRelease:
    if releaseTag.len == 0:
      asset.githubLatestReleaseAssetUrl()
    else:
      asset.githubReleaseAssetUrl(releaseTag)
  of Upstream:
    asset.upstreamVsixUrl()

proc findGrammarReleaseAsset*(packageKey: string): Option[GrammarReleaseAsset] =
  ## Finds a grammar release asset by its upstream extension ID.
  for asset in grammarReleaseAssets:
    if asset.packageKey == packageKey:
      return some(asset)
  none(GrammarReleaseAsset)
