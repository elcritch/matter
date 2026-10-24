import std/[json, options, os, sequtils, strutils, unittest]

import matter
import matter/grammarloader

const nifSource = staticRead("../grammars/nif/nif.tmLanguage.json")
const root = currentSourcePath.parentDir.parentDir

proc newNifGrammar(): Grammar =
  let registry = newRegistry()
  registry.addGrammar(parseRawGrammar(nifSource, "nif.tmLanguage.json"))
  registry.loadGrammar("source.nif")

proc checkScope(parsed: TokenizeLineResult, source, fragment, scope: string) =
  checkpoint("Expected " & scope & " on " & fragment)
  let start = source.find(fragment)
  require start >= 0
  for offset in start ..< start + fragment.len:
    check parsed.tokens.anyIt(
      it.startIndex <= offset and offset < it.endIndex and scope in it.scopes
    )

suite "NIF TextMate grammar":
  test "declares the file extension and version cookie":
    let raw = parseJson(nifSource)
    check raw["scopeName"].getStr == "source.nif"
    check raw["fileTypes"][0].getStr == "nif"
    check raw["firstLineMatch"].getStr == r"^\(\.nif[0-9]+\)"

  test "loads the authored grammar through the bundled catalog":
    check findGrammar("source.nif").get == nifGrammar
    check nifGrammar.languageId == "nif"
    let source = zipResourceSource(root)
    check source(nifGrammar).get == nifSource
    let registry = newRegistry()
    let loaded = registry.loadGrammarPackage(source, "source.nif")
    check loaded.loadedScopeNames == @["source.nif"]
    check loaded.unresolvedIncludes.len == 0
    let grammar = registry.loadGrammar("source.nif")
    let line = "(call write.1.sys \"Hello World!\")"
    checkScope(grammar.tokenizeLine(line), line, "call", "entity.name.tag.nif")

  test "recognizes extensible tags directives and nested nodes":
    let grammar = newNifGrammar()
    for directive in [".nif27", ".lang", ".vendor", ".index", ".future"]:
      let line = "(" & directive & " \"value\")"
      let parsed = grammar.tokenizeLine(line)
      checkScope(parsed, line, directive, "keyword.control.directive.nif")
      check parsed.completedRuleStack.depth == 1
    let line = "(custom (true) true (future_tag x))"
    let parsed = grammar.tokenizeLine(line)
    checkScope(parsed, line, "custom", "entity.name.tag.nif")
    checkScope(parsed, line, "future_tag", "entity.name.tag.nif")
    checkScope(parsed, line, "x", "variable.other.identifier.nif")
    check parsed.tokens.countIt("entity.name.tag.nif" in it.scopes) == 3
    check parsed.completedRuleStack.depth == 1

  test "distinguishes symbols definitions identifiers and adjacent empty nodes":
    let grammar = newNifGrammar()
    let line = r"(proc :foo.0.mod foo.0 foo.0. foo.1.key.mod plain ... \2B.0.mod)"
    let parsed = grammar.tokenizeLine(line)
    checkScope(parsed, line, ":", "punctuation.definition.symbol.nif")
    checkScope(parsed, line, "foo.0.mod", "entity.name.symbol.nif")
    checkScope(parsed, line, "foo.1.key.mod", "variable.other.symbol.nif")
    checkScope(parsed, line, "plain", "variable.other.identifier.nif")
    checkScope(parsed, line, "...", "constant.language.empty.nif")
    checkScope(parsed, line, r"\2B.0.mod", "variable.other.symbol.nif")
    checkScope(parsed, line, r"\2B", "constant.character.escape.nif")
    for symbol in ["foo.0", "foo.0."]:
      let isolated = grammar.tokenizeLine(symbol)
      checkScope(isolated, symbol, symbol, "variable.other.symbol.nif")

  test "highlights decimal integers unsigned numbers and exponent floats":
    let grammar = newNifGrammar()
    for (literal, scope) in [
      ("0", "integer"),
      ("12", "integer"),
      ("-12", "integer"),
      ("123u", "unsigned"),
      ("-1u", "unsigned"),
      ("1.25", "float"),
      ("-1.25E+10", "float"),
      ("1E-3", "float"),
      ("1E3", "float"),
    ]:
      let line = "(value " & literal & ")"
      checkScope(
        grammar.tokenizeLine(line), line, literal, "constant.numeric." & scope & ".nif"
      )

  test "recognizes base62 suffix locations and escaped filenames":
    let grammar = newNifGrammar()
    for annotation in [
      "@5", "@A,z", "@~3,~Z", "~3", "~a,2", "@,", "@,,foo.nim", r"@1,1,path\20name.nim"
    ]:
      let line = "(call" & annotation & " x)"
      let parsed = grammar.tokenizeLine(line)
      checkScope(parsed, line, annotation, "constant.other.location.nif")
      checkScope(parsed, line, "call", "entity.name.tag.nif")
      checkScope(parsed, line, "x", "variable.other.identifier.nif")
    for atom in ["123", "foo", "foo.0", ":foo.0", "'x'", "\"hello\"", "."]:
      let line = "(value " & atom & "@5,3,foo.nim#why#)"
      let parsed = grammar.tokenizeLine(line)
      checkScope(parsed, line, "@5,3,foo.nim", "constant.other.location.nif")
      checkScope(parsed, line, "#why#", "comment.block.nif")

  test "based integers and digit separators retain their complete numeric scopes":
    let grammar = newNifGrammar()
    for (literal, scope) in [
      ("0xFF", "integer"),
      ("0xff", "integer"),
      ("-0xFF", "integer"),
      ("0x00_82_9f_ff", "integer"),
      ("0x1E3", "integer"),
      ("0o377", "integer"),
      ("0o3_77u", "unsigned"),
      ("0b1111_1111", "integer"),
      ("-0b1u", "unsigned"),
      ("0xDEAD_BEEFu", "unsigned"),
      ("1_000_000", "integer"),
      ("1_000u", "unsigned"),
      ("1_234.5_6E+0_2", "float"),
      ("-1_0.5_0", "float"),
      ("1E1_0", "float"),
    ]:
      let line = "(value " & literal & "@5#number#)"
      let parsed = grammar.tokenizeLine(line)
      checkScope(parsed, line, literal, "constant.numeric." & scope & ".nif")
      checkScope(parsed, line, "@5", "constant.other.location.nif")
      checkScope(parsed, line, "#number#", "comment.block.nif")

  test "malformed numbers do not highlight partial numeric suffixes":
    let grammar = newNifGrammar()
    for literal in [
      "0x", "0o8", "0b102", "0x_FF", "0xFFG", "0o178", "0XFF", "1_", "1__2", "1_.0",
      "1._0", "1E_2", "1E+_2", "1_u", "1E", "1E+", "+12", "--12", "1.25e3",
    ]:
      let line = "(value " & literal & ")"
      let parsed = grammar.tokenizeLine(line)
      checkpoint literal
      check not parsed.tokens.anyIt(it.scopes.anyIt(it.startsWith("constant.numeric.")))

  test "quoted punctuation stays in strings while suffix comments remain separate":
    let grammar = newNifGrammar()
    for text in ["#language:hover", "2026-10-24T12:00:00Z", "key: value; # text"]:
      let line = "(value \"" & text & "\"#comment#)"
      let parsed = grammar.tokenizeLine(line)
      checkScope(parsed, line, text, "string.quoted.double.nif")
      checkScope(parsed, line, "#comment#", "comment.block.nif")
      check parsed.tokens.countIt(
        "punctuation.definition.comment.begin.nif" in it.scopes
      ) == 1
      check parsed.completedRuleStack.depth == 1
    let opening = grammar.tokenizeLine("(value \"#literal: first;")
    let closingLine = "#literal: second;\"#suffix#)"
    let closing = grammar.tokenizeLine(closingLine, opening.completedRuleStack)
    checkScope(closing, closingLine, "#literal: second;", "string.quoted.double.nif")
    checkScope(closing, closingLine, "#suffix#", "comment.block.nif")
    check closing.completedRuleStack.depth == 1

  test "recognizes hex and shortcut escapes in literals comments and identifiers":
    let grammar = newNifGrammar()
    for escape in [r"\00", r"\5C", r"\FF", r"\n", r"\t", r"\r", r"\|", r"\^"]:
      for line in [
        "\"" & escape & "\"", "'" & escape & "'", "x#" & escape & "#", "name" & escape
      ]:
        let parsed = grammar.tokenizeLine(line)
        checkScope(parsed, line, escape, "constant.character.escape.nif")
        check not parsed.tokens.anyIt("invalid.illegal.escape.nif" in it.scopes)
    for escape in [r"\g", r"\0a", r"\\"]:
      let line = "\"" & escape & "\""
      let parsed = grammar.tokenizeLine(line)
      check parsed.tokens.anyIt("invalid.illegal.escape.nif" in it.scopes)
      check not parsed.tokens.anyIt("constant.character.escape.nif" in it.scopes)

  test "preserves multiline strings comments and nested node state":
    let grammar = newNifGrammar()
    let first = grammar.tokenizeLine("(stmts (call \"a")
    check first.completedRuleStack.hasActiveScope("string.quoted.double.nif")
    let secondLine = "b\"#a comment"
    let second = grammar.tokenizeLine(secondLine, first.completedRuleStack)
    checkScope(second, secondLine, "b", "string.quoted.double.nif")
    check second.completedRuleStack.hasActiveScope("comment.block.nif")
    let thirdLine = "continued# value))"
    let third = grammar.tokenizeLine(thirdLine, second.completedRuleStack)
    checkScope(third, thirdLine, "continued", "comment.block.nif")
    checkScope(third, thirdLine, "value", "variable.other.identifier.nif")
    check third.completedRuleStack.depth == 1

  test "handles non-ASCII identifiers tags symbols and literals with byte offsets":
    let grammar = newNifGrammar()
    let line = "(λ :café.0.mod naïve.0 'é' \"日本語\")"
    let parsed = grammar.tokenizeLine(line)
    checkScope(parsed, line, "λ", "entity.name.tag.nif")
    checkScope(parsed, line, "café.0.mod", "entity.name.symbol.nif")
    checkScope(parsed, line, "naïve.0", "variable.other.symbol.nif")
    checkScope(parsed, line, "é'", "string.quoted.single.nif")
    checkScope(parsed, line, "日本語", "string.quoted.double.nif")

  test "NIF 2026 cookie selects legacy prefix locations and signed numbers":
    let grammar = newNifGrammar()
    let header = grammar.tokenizeLine("(.nif26)")
    check header.completedRuleStack.hasActiveScope("meta.version.26.nif")
    let line =
      "1,1,foo.nim(stmts #prefix#(value +12 -12 +3u +1.5E-2 8 x ~3 y ,,file.nim z))"
    let parsed = grammar.tokenizeLine(line, header.completedRuleStack)
    for location in ["1,1,foo.nim", "8", "~3", ",,file.nim"]:
      checkScope(parsed, line, location, "constant.other.location.nif")
    for (literal, scope) in [
      ("+12", "integer"), ("-12", "integer"), ("+3u", "unsigned"), ("+1.5E-2", "float")
    ]:
      checkScope(parsed, line, literal, "constant.numeric." & scope & ".nif")
    checkScope(parsed, line, "#prefix#", "comment.block.nif")
    check parsed.completedRuleStack.depth == header.completedRuleStack.depth
    let sameLine = "(.nif26)(value +42)"
    checkScope(
      grammar.tokenizeLine(sameLine), sameLine, "+42", "constant.numeric.integer.nif"
    )
    let modernLine = "(.nif27)(value 42)"
    let modern = grammar.tokenizeLine(modernLine)
    checkScope(modern, modernLine, "42", "constant.numeric.integer.nif")
    check not modern.completedRuleStack.hasActiveScope("meta.version.26.nif")

  test "line-based tags and auto strings preserve number and suffix scopes":
    let grammar = newNifGrammar()
    let header = grammar.tokenizeLine("(.nif27)")
    let line = "copy src/main.nim dest/main.nim@1#target# 0xFF 1E-3"
    let parsed = grammar.tokenizeLine(line, header.completedRuleStack)
    checkScope(parsed, line, "copy", "entity.name.tag.nif")
    checkScope(parsed, line, "src/main.nim", "string.unquoted.nif")
    checkScope(parsed, line, "dest/main.nim", "string.unquoted.nif")
    checkScope(parsed, line, "@1", "constant.other.location.nif")
    checkScope(parsed, line, "#target#", "comment.block.nif")
    checkScope(parsed, line, "0xFF", "constant.numeric.integer.nif")
    checkScope(parsed, line, "1E-3", "constant.numeric.float.nif")
    check parsed.completedRuleStack.hasActiveScope("meta.syntax.line-based.nif")
    let nextLine = "warn 2024-08-12 key: -13 0o7"
    let continued = grammar.tokenizeLine(nextLine, parsed.completedRuleStack)
    checkScope(continued, nextLine, "warn", "entity.name.tag.nif")
    checkScope(continued, nextLine, "2024-08-12", "string.unquoted.nif")
    checkScope(continued, nextLine, "key:", "string.unquoted.nif")
    checkScope(continued, nextLine, "-13", "constant.numeric.integer.nif")
    checkScope(continued, nextLine, "0o7", "constant.numeric.integer.nif")
    let pathsLine = "copy /usr/bin --color https://nim-lang.org -3 1.5E-3 x.1"
    let paths = grammar.tokenizeLine(pathsLine, continued.completedRuleStack)
    for path in ["/usr/bin", "--color", "https://nim-lang.org"]:
      checkScope(paths, pathsLine, path, "string.unquoted.nif")
    checkScope(paths, pathsLine, "-3", "constant.numeric.integer.nif")
    checkScope(paths, pathsLine, "1.5E-3", "constant.numeric.float.nif")
    checkScope(paths, pathsLine, "x.1", "variable.other.symbol.nif")

  test "line-based style rules retain nested state across lines":
    let grammar = newNifGrammar()
    let firstLine = "style \"#name:hover\" (rule"
    let first = grammar.tokenizeLine(firstLine)
    checkScope(first, firstLine, "style", "entity.name.tag.nif")
    checkScope(first, firstLine, "#name:hover", "string.quoted.double.nif")
    let secondLine = "  (background (color 0x00_ff_00)))"
    let second = grammar.tokenizeLine(secondLine, first.completedRuleStack)
    checkScope(second, secondLine, "color", "entity.name.tag.nif")
    checkScope(second, secondLine, "0x00_ff_00", "constant.numeric.integer.nif")
    check second.completedRuleStack.hasActiveScope("meta.syntax.line-based.nif")
    check not second.completedRuleStack.hasActiveScope("meta.node.line-based.nif")
    let core = grammar.tokenizeLine("(value foo/bar)")
    check not core.tokens.anyIt("string.unquoted.nif" in it.scopes)

  test "bundled Markdown dispatches nif fences to the grammar":
    let registry = newRegistry()
    discard registry.loadGrammarPackage(
      zipResourceSource(root), ["text.html.markdown", "source.nif"]
    )
    let markdown = registry.loadGrammar("text.html.markdown")
    let opening = markdown.tokenizeLine("```nif")
    let line = "(call foo.0 0x82_9f_ff \"#color: value;\")"
    let body = markdown.tokenizeLine(line, opening.completedRuleStack)
    checkScope(body, line, "call", "entity.name.tag.nif")
    checkScope(body, line, "0x82_9f_ff", "constant.numeric.integer.nif")
    checkScope(body, line, "#color: value;", "string.quoted.double.nif")
    let closing = markdown.tokenizeLine("```", body.completedRuleStack)
    check not closing.completedRuleStack.hasActiveScope("markup.fenced_code")
    let lineOpening = markdown.tokenizeLine("```nif")
    let lineBody = markdown.tokenizeLine(
      "style \"#name:hover\" (rule (color 0xfff))", lineOpening.completedRuleStack
    )
    let lineClosing = markdown.tokenizeLine("```", lineBody.completedRuleStack)
    check not lineClosing.completedRuleStack.hasActiveScope("markup.fenced_code")
