import std/unittest

import matter

suite "Open VSX grammar package catalog":
  test "exposes pinned package metadata":
    check nimVscodePackage.extensionId() == "nimsaem.nimvscode"
    check nimVscodePackage.version == "0.1.26"
    check nimVscodePackage.licenseId == "MIT"
    check vscodeCppPackage.extensionId() == "vscode.cpp"
    check vscodeCppPackage.version == "1.95.3"
    check vscodePythonPackage.extensionId() == "vscode.python"
    check vscodePythonPackage.version == "1.95.3"
    check knownPackages.len == 3

  test "records primary and supporting grammar contributions":
    check nimGrammar.scopeName == "source.nim"
    check nimGrammar.grammarPath == "./syntaxes/nim.json"
    check nimbleGrammar.scopeName == "source.nimble"
    check nimbleGrammar.grammarPath == "./syntaxes/nimble.json"
    check cGrammar.scopeName == "source.c"
    check cGrammar.grammarPath == "./syntaxes/c.tmLanguage.json"
    check cppGrammar.scopeName == "source.cpp"
    check cppGrammar.grammarPath == "./syntaxes/cpp.tmLanguage.json"
    check pythonGrammar.scopeName == "source.python"
    check pythonGrammar.grammarPath == "./syntaxes/MagicPython.tmLanguage.json"
    check cppGrammar.packageKey == vscodeCppPackage.extensionId()
    check cppEmbeddedMacroGrammar.scopeName == "source.cpp.embedded.macro"
    check cppEmbeddedMacroGrammar.grammarPath ==
      "./syntaxes/cpp.embedded.macro.tmLanguage.json"
    check cPlatformGrammar.languageId == ""
    check cPlatformGrammar.grammarPath == "./syntaxes/platform.tmLanguage.json"
    check pythonRegexpGrammar.scopeName == "source.regexp.python"
    check pythonRegexpGrammar.grammarPath == "./syntaxes/MagicRegExp.tmLanguage.json"
    check nimGrammar.isPrimary
    check not cPlatformGrammar.isPrimary
    check knownGrammars.len == 8

  test "constructs deterministic Open VSX URLs":
    check vscodeCppPackage.versionMetadataUrl() ==
      "https://open-vsx.org/api/vscode/cpp/1.95.3"
    check vscodePythonPackage.latestMetadataUrl() ==
      "https://open-vsx.org/api/vscode/python/latest"
    check nimVscodePackage.vsixDownloadUrl() ==
      "https://open-vsx.org/api/nimsaem/nimvscode/0.1.26/file/nimsaem.nimvscode-0.1.26.vsix"
    check vsixDownloadUrl("example", "grammar", "1.2.3") ==
      "https://open-vsx.org/api/example/grammar/1.2.3/file/example.grammar-1.2.3.vsix"
