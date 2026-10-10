## Reproduce CSS tokenization performance using the checked-in Merenda theme.
## nim c -d:release --path:src -o:/tmp/bench_css tools/bench_css.nim
## /tmp/bench_css [passes=3] [timeLimitMs=0] [snapshotPath] [cssPath]

import std/[algorithm, json, monotimes, os, strutils, times]

import pkg/zippy/crc

import matter

const fixtureDir = currentSourcePath.parentDir.parentDir / "tests/fixtures/css"

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
      fixtureDir / "synthwave83.css"
  lines = readFile(sourcePath).splitLines()
  registry = newRegistry()

if passes <= 0 or timeLimitMs < 0:
  quit "passes must be positive and timeLimitMs must be nonnegative"
echo "CSS: ", sourcePath
registry.addGrammar(
  parseRawGrammar(readFile(fixtureDir / "css.tmLanguage.json"), "css.tmLanguage.json")
)
let compileStarted = getMonoTime()
let grammar = registry.loadGrammar("source.css")
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
