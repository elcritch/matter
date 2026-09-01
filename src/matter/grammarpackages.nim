## Known Open VSX packages containing MIT-licensed TextMate grammars.
##
## This module only describes pinned package metadata and constructs direct
## Open VSX URLs. Downloading and VSIX extraction remain the caller's job.

type
  OpenVsxPackage* = object ## A pinned Open VSX extension package.
    namespace*: string
    name*: string
    version*: string
    licenseId*: string
    ## SPDX license identifier for the package's grammar sources.
    repositoryUrl*: string
    licenseUrl*: string

  LanguageGrammar* = object ## A TextMate grammar supplied by a known package.
    displayName*: string
    languageId*: string
    scopeName*: string
    grammarPath*: string
    ## Path from the VSIX manifest to the contributed grammar file.
    packageKey*: string
    ## The package's ``extensionId``; use it to associate this grammar with a
    ## catalog package.
    isPrimary*: bool ## Whether this grammar is the primary grammar for its language.

const
  openVsxApiBaseUrl* = "https://open-vsx.org/api"
  ## Base URL for Open VSX extension metadata and files.
  nimVscodePackage* = OpenVsxPackage(
    namespace: "nimsaem",
    name: "nimvscode",
    version: "0.1.26",
    licenseId: "MIT",
    repositoryUrl: "https://github.com/saem/vscode-nim",
    licenseUrl: "https://github.com/saem/vscode-nim/blob/main/LICENSE",
  )

  vscodeCppPackage* = OpenVsxPackage(
    namespace: "vscode",
    name: "cpp",
    version: "1.95.3",
    licenseId: "MIT",
    repositoryUrl: "https://github.com/microsoft/vscode/tree/main/extensions/cpp",
    licenseUrl: "https://github.com/microsoft/vscode/blob/main/LICENSE.txt",
  )

  vscodePythonPackage* = OpenVsxPackage(
    namespace: "vscode",
    name: "python",
    version: "1.95.3",
    licenseId: "MIT",
    repositoryUrl: "https://github.com/microsoft/vscode/tree/main/extensions/python",
    licenseUrl: "https://github.com/microsoft/vscode/blob/main/LICENSE.txt",
  )

  knownPackages* = [nimVscodePackage, vscodeCppPackage, vscodePythonPackage]
  ## The complete catalog of downloadable grammar packages.
  nimGrammar* = LanguageGrammar(
    displayName: "Nim",
    languageId: "nim",
    scopeName: "source.nim",
    grammarPath: "./syntaxes/nim.json",
    packageKey: "nimsaem.nimvscode",
    isPrimary: true,
  )

  nimbleGrammar* = LanguageGrammar(
    displayName: "Nimble",
    languageId: "nimble",
    scopeName: "source.nimble",
    grammarPath: "./syntaxes/nimble.json",
    packageKey: "nimsaem.nimvscode",
    isPrimary: true,
  )

  cGrammar* = LanguageGrammar(
    displayName: "C",
    languageId: "c",
    scopeName: "source.c",
    grammarPath: "./syntaxes/c.tmLanguage.json",
    packageKey: "vscode.cpp",
    isPrimary: true,
  )

  cppGrammar* = LanguageGrammar(
    displayName: "C++",
    languageId: "cpp",
    scopeName: "source.cpp",
    grammarPath: "./syntaxes/cpp.tmLanguage.json",
    packageKey: "vscode.cpp",
    isPrimary: true,
  )

  pythonGrammar* = LanguageGrammar(
    displayName: "Python",
    languageId: "python",
    scopeName: "source.python",
    grammarPath: "./syntaxes/MagicPython.tmLanguage.json",
    packageKey: "vscode.python",
    isPrimary: true,
  )

  cppEmbeddedMacroGrammar* = LanguageGrammar(
    displayName: "C++ Embedded Macro Support",
    languageId: "cpp",
    scopeName: "source.cpp.embedded.macro",
    grammarPath: "./syntaxes/cpp.embedded.macro.tmLanguage.json",
    packageKey: "vscode.cpp",
  )

  cPlatformGrammar* = LanguageGrammar(
    displayName: "C Platform Support",
    scopeName: "source.c.platform",
    grammarPath: "./syntaxes/platform.tmLanguage.json",
    packageKey: "vscode.cpp",
  )

  pythonRegexpGrammar* = LanguageGrammar(
    displayName: "Python Regular Expression Support",
    scopeName: "source.regexp.python",
    grammarPath: "./syntaxes/MagicRegExp.tmLanguage.json",
    packageKey: "vscode.python",
  )

  knownGrammars* = [
    nimGrammar, nimbleGrammar, cGrammar, cppGrammar, pythonGrammar,
    cppEmbeddedMacroGrammar, cPlatformGrammar, pythonRegexpGrammar,
  ]
  ## The complete catalog of primary and support grammars.

func extensionId*(package: OpenVsxPackage): string =
  ## Returns the Open VSX extension identifier, such as ``vscode.cpp``.
  package.namespace & "." & package.name

func versionMetadataUrl*(namespace, name, version: string): string =
  ## Returns the Open VSX API URL for a specific extension version.
  openVsxApiBaseUrl & "/" & namespace & "/" & name & "/" & version

func versionMetadataUrl*(package: OpenVsxPackage): string =
  ## Returns the metadata URL for this package's pinned version.
  versionMetadataUrl(package.namespace, package.name, package.version)

func latestMetadataUrl*(package: OpenVsxPackage): string =
  ## Returns the metadata URL for the latest available package version.
  versionMetadataUrl(package.namespace, package.name, "latest")

func vsixDownloadUrl*(namespace, name, version: string): string =
  ## Returns the direct versioned VSIX file URL.
  let extension = namespace & "." & name & "-" & version & ".vsix"
  versionMetadataUrl(namespace, name, version) & "/file/" & extension

func vsixDownloadUrl*(package: OpenVsxPackage): string =
  ## Returns the direct VSIX URL for this package's pinned version.
  vsixDownloadUrl(package.namespace, package.name, package.version)
