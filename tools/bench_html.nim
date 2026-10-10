## Reproduce HTML tokenization performance using the checked-in Merenda document.
## nim c -d:release --path:src -o:/tmp/bench_html tools/bench_html.nim
## /tmp/bench_html [passes=3] [timeLimitMs=0] [snapshotPath] [htmlPath] [scope]

import std/[algorithm, json, monotimes, os, strutils, times]

import pkg/zippy/crc

import matter
import matter/grammarloader

const fixtureDir = currentSourcePath.parentDir.parentDir / "tests/fixtures/html"

let
  passes =
    if paramCount() > 0:
      parseInt(paramStr(1))
    else:
      3
  timeLimitMs =
    if paramCount() > 1:
      parseInt(paramStr(2))
    else:
      0
  sourcePath =
    if paramCount() > 3:
      paramStr(4)
    else:
      fixtureDir / "merenda.html"
  scope =
    if paramCount() > 4:
      paramStr(5)
    else:
      "text.html.derivative"
  lines = readFile(sourcePath).splitLines()
  registry = newRegistry()

if passes <= 0 or timeLimitMs < 0:
  quit "passes must be positive and timeLimitMs must be nonnegative"
echo "HTML: ", sourcePath
let compileStarted = getMonoTime()
let loaded = registry.loadGrammarPackage(
  zipResourceSource(currentSourcePath.parentDir.parentDir), scope
)
let grammar = registry.loadGrammar(scope)
echo "Registered grammars: ",
  loaded.loadedScopeNames.len, "; optional unresolved includes: ",
  loaded.unresolvedIncludes.len
echo "Grammar compilation: ",
  (getMonoTime() - compileStarted).inMicroseconds.float / 1000, " ms"
stdout.flushFile()

for pass in 1 .. passes:
  var
    state: StateStack
    durations: seq[(int64, int)]
    snapshot: string
    tokens, stopped: int
  let started = getMonoTime()
  for index, line in lines:
    let lineStarted = getMonoTime()
    let parsed = grammar.tokenizeLine(line, state, timeLimitMs)
    durations.add(((getMonoTime() - lineStarted).inMicroseconds, index + 1))
    tokens += parsed.tokens.len
    if parsed.stoppedEarly:
      inc stopped
      state = nil
    else:
      state = parsed.completedRuleStack
    snapshot.add($(%parsed.tokens) & "\n")
  let elapsed = (getMonoTime() - started).inMicroseconds.float / 1000
  durations.sort(SortOrder.Descending)
  echo "Pass ",
    pass,
    ": ",
    lines.len,
    " lines, ",
    tokens,
    " tokens, ",
    stopped,
    " stopped; ",
    elapsed,
    " ms; ",
    lines.len.float * 1000 / elapsed,
    " lines/s"
  echo "  Token CRC32: ", crc32(snapshot).toHex(8)
  echo "  Slowest lines (microseconds, line): ", durations[0 ..< min(5, durations.len)]
  if pass == 1 and paramCount() > 2 and paramStr(3).len > 0:
    writeFile(paramStr(3), snapshot)
  stdout.flushFile()
