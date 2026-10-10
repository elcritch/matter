## Compare tokenizer throughput using the same prepared grammars on any revision.
## Arguments: grammarDir scope input warmups samples snapshot [overrideGrammar]
## Tokenization timings exclude loading, compilation, normalization, and JSON.

import std/[algorithm, json, monotimes, os, strutils, times]

import matter

if paramCount() notin 6 .. 7:
  quit "Usage: bench_compare grammarDir scope input warmups samples snapshot [overrideGrammar]"

let
  warmups = parseInt(paramStr(4))
  samples = parseInt(paramStr(5))
  lines = readFile(paramStr(3)).splitLines()
  registry = newRegistry()

if warmups < 0 or samples <= 0:
  quit "warmups must be nonnegative and samples must be positive"

var files: seq[string]
for file in walkFiles(paramStr(1) / "*.tmLanguage.json"):
  files.add(file)
files.sort()
if files.len == 0:
  quit "no prepared grammars found"

let loadStarted = getMonoTime()
for file in files:
  registry.addGrammar(parseRawGrammar(readFile(file), file))
if paramCount() == 7:
  let file = paramStr(7)
  registry.addGrammar(parseRawGrammar(readFile(file), file))
let grammar = registry.loadGrammar(paramStr(2))
let loadMs = (getMonoTime() - loadStarted).inNanoseconds.float / 1_000_000

proc document(): int =
  var state: StateStack
  for line in lines:
    let parsed = grammar.tokenizeLine(line, state)
    if parsed.stoppedEarly:
      quit "unexpected interrupted line in unlimited benchmark"
    state = parsed.ruleStack
    result += parsed.tokens.len

for _ in 0 ..< warmups:
  discard document()
var
  elapsed: seq[float]
  rawTokens: int
for _ in 0 ..< samples:
  let started = getMonoTime()
  rawTokens = document()
  elapsed.add((getMonoTime() - started).inNanoseconds.float / 1_000_000)

# Capture the whole output separately so correctness checking does not affect
# the engine timing. Also measure the UTF-8/JSON workload used by older tools.
var
  state: StateStack
  snapshot: string
let snapshotStarted = getMonoTime()
for line in lines:
  let parsed = grammar.tokenizeLine(line, state)
  state = parsed.ruleStack
  snapshot.add($(%parsed.tokens) & "\n")
let snapshotMs = (getMonoTime() - snapshotStarted).inNanoseconds.float / 1_000_000
writeFile(paramStr(6), snapshot)
echo %*{
  "engine": "matter",
  "scope": paramStr(2),
  "input": paramStr(3),
  "lines": lines.len,
  "rawTokens": rawTokens,
  "warmups": warmups,
  "loadAndCompileMs": loadMs,
  "tokenizeMs": elapsed,
  "tokenizeAndSnapshotMs": snapshotMs,
}
