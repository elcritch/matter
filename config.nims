import std/[os, strutils]

--mm:atomicArc
--threads:on

task test, "run unit tests":
  for testFile in listFiles("tests/"):
    if testFile.endsWith(".nim") and testFile.splitFile().name.startsWith("t"):
      exec("nim c -r " & quoteShell(testFile))

task regenerateGrammars, "download and reproducibly rebuild bundled grammar ZIPs":
  exec("python3 " & quoteShell("tools/regenerate_grammars.py"))

task verifyGrammars, "verify bundled grammar ZIPs without network access":
  exec("python3 " & quoteShell("tools/regenerate_grammars.py") & " --verify")
