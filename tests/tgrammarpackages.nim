import std/[options, os, strutils, tempfiles, unittest]

import matter

const moeModes = [
  "astro", "c", "commitEditMsg", "cpp", "csharp", "diff", "dockerfile", "fish",
  "gitRebaseTodo", "gitignore", "go", "haskell", "html", "hyprland", "java",
  "javascript", "jsx", "latex", "lisp", "log", "lua", "markdown", "nim", "python",
  "rust", "shell", "tcl", "toml", "yaml", "json", "jsonc", "typescript", "tsx", "xml",
  "zsh",
]

suite "grammar package catalog":
  test "exposes pinned source and archive metadata":
    check knownPackages.len == 30
    check knownGrammars.len == 55
    check nimVscodePackage.extensionId() == "nimsaem.nimvscode"
    check vscodeCppPackage.version == "1.95.3"
    check tomlPackage.licenseId == "MIT"
    check haskellPackage.licenseId == "BSD-3-Clause"
    check astroPackage.targetPlatform == "alpine-arm64"
    check astroPackage.vsixDownloadUrl() ==
      "https://open-vsx.org/api/astro-build/astro-vscode/alpine-arm64/2.16.20/file/" &
      "astro-build.astro-vscode-2.16.20@alpine-arm64.vsix"
    check tclPackage.vsixDownloadUrl() ==
      "https://github.com/bitwisecook/vscode-tcl/releases/download/0.4.3/tcl-0.4.3.vsix"
    check terraformSyntaxPackage.sourceKind == "github-archive"
    check terraformSyntaxPackage.licenseId == "MPL-2.0"
    check terraformSyntaxPackage.sourceArchiveUrl() ==
      "https://github.com/hashicorp/syntax/archive/refs/tags/v0.7.1.zip"
    check terraformPlanPackage.sourceKind == "github-archive"
    check terraformPlanPackage.licenseId == "MIT"
    check terraformGrammar.scopeName == "source.hcl.terraform"
    check terraformPlanGrammar.scopeName == "source.tofu-plan"
    for package in knownPackages:
      check package.licenseId.len > 0
      check package.repositoryUrl.startsWith("https://")
      check package.licenseUrl.startsWith("https://")
      check package.downloadUrl.startsWith("https://")
      check package.dataArchivePath.startsWith("data/grammars/")
      check package.sourceArchiveSha256.len == 64
      if package.sourceKind == "vsix":
        check package.sourceVsixSha256 == package.sourceArchiveSha256
      else:
        check package.sourceVsixSha256.len == 0
      check package.archiveSha256.len == 64

  test "maps every current Moe source mode":
    check moeGrammarMappings.len == moeModes.len
    for mode in moeModes:
      let grammar = findMoeGrammar(mode)
      check grammar.isSome
      if grammar.isSome:
        check grammar.get.scopeName.len > 0
        check grammar.get.dataArchivePath.startsWith("data/grammars/")
    check findMoeGrammar("none").isNone
    check findMoeGrammar("zsh").get.scopeName == "source.shell"
    check findMoeGrammar("xml").get.scopeName == "text.xml"
    check cabalGrammar.scopeName == "source.cabal"
    check xslGrammar.scopeName == "text.xml.xsl"
    var cppImports: seq[GrammarContribution]
    for grammar in importedGrammars("cpp"):
      cppImports.add(grammar)
    check cppImports[0].scopeName == "source.cpp"

  test "keeps direct Open VSX URL helpers":
    check vscodeCppPackage.versionMetadataUrl() ==
      "https://open-vsx.org/api/vscode/cpp/1.95.3"
    check vscodePythonPackage.latestMetadataUrl() ==
      "https://open-vsx.org/api/vscode/python/latest"
    check nimVscodePackage.vsixDownloadUrl() ==
      "https://open-vsx.org/api/nimsaem/nimvscode/0.1.26/file/nimsaem.nimvscode-0.1.26.vsix"
    check vsixDownloadUrl("example", "grammar", "1.2.3") ==
      "https://open-vsx.org/api/example/grammar/1.2.3/file/example.grammar-1.2.3.vsix"

  test "offline verifier validates checksums and ZIP metadata":
    let root = currentSourcePath.parentDir.parentDir
    check execShellCmd(
      "python3 " & quoteShell(root / "tools/regenerate_grammars.py") & " --verify"
    ) == 0

  test "offline verifier rejects catalog drift from the source manifest":
    let root = currentSourcePath.parentDir.parentDir
    let (temporaryFile, driftedCatalog) =
      createTempFile("matter-grammar-catalog-", ".json")
    close(temporaryFile)
    defer:
      if fileExists(driftedCatalog):
        removeFile(driftedCatalog)
    let original = readFile(root / "data/grammars/catalog.json")
    writeFile(
      driftedCatalog,
      original.replace("\"licenseId\": \"MIT\"", "\"licenseId\": \"Apache-2.0\""),
    )
    check execShellCmd(
      "python3 " & quoteShell(root / "tools/regenerate_grammars.py") &
        " --verify --catalog " & quoteShell(driftedCatalog)
    ) != 0
