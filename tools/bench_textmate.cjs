// Comparable VS Code TextMate/Oniguruma timing; see tools/BENCHMARK.md.
const fs = require("fs");
const path = require("path");
const { performance } = require("perf_hooks");
const textmate = require("vscode-textmate");
const { readGrammars, createRegistry, visibleTokens } = require("./reference_tokens.cjs");

async function main() {
  const args = process.argv.slice(2);
  if (args[0] === "--prepare" && args.length === 3) {
    // Use identical JSON grammars in Nim and JS, excluding Matter's extension.
    const grammars = readGrammars(args[1]);
    fs.mkdirSync(args[2], { recursive: true });
    for (const [scope, raw] of grammars) {
      fs.writeFileSync(path.join(args[2], scope + ".tmLanguage.json"), JSON.stringify(raw));
    }
    return;
  }
  if (args.length < 6 || args.length > 7) {
    throw new Error("Usage: bench_textmate.cjs grammarDir scope input warmups samples snapshot [overrideGrammar]");
  }
  const [grammarDir, scope, sourcePath, warmupArg, sampleArg, snapshotPath, override] = args;
  const warmups = Number(warmupArg), samples = Number(sampleArg);
  if (!Number.isInteger(warmups) || warmups < 0 || !Number.isInteger(samples) || samples <= 0) {
    throw new Error("warmups must be nonnegative and samples must be positive");
  }
  const lines = fs.readFileSync(sourcePath, "utf8").split(/\r?\n/);
  const loadStarted = performance.now();
  const grammars = readGrammars(grammarDir);
  if (override) {
    const raw = textmate.parseRawGrammar(fs.readFileSync(override, "utf8"), override);
    grammars.set(raw.scopeName, raw);
  }
  const registry = await createRegistry(grammars);
  try {
    const grammar = await registry.loadGrammar(scope);
    if (!grammar) throw new Error("Missing grammar: " + scope);
    const loadAndCompileMs = performance.now() - loadStarted;
    function document() {
      let state = textmate.INITIAL, tokens = 0;
      for (const line of lines) {
        const parsed = grammar.tokenizeLine(line, state);
        if (parsed.stoppedEarly) throw new Error("Unexpected interrupted line");
        state = parsed.ruleStack;
        tokens += parsed.tokens.length;
      }
      return tokens;
    }
    for (let i = 0; i < warmups; i++) document();
    const tokenizeMs = [];
    let rawTokens;
    for (let i = 0; i < samples; i++) {
      const started = performance.now();
      rawTokens = document();
      tokenizeMs.push(performance.now() - started);
    }
    let state = textmate.INITIAL, snapshot = "";
    const snapshotStarted = performance.now();
    for (const line of lines) {
      const parsed = grammar.tokenizeLine(line, state);
      state = parsed.ruleStack;
      snapshot += JSON.stringify(visibleTokens(line, parsed.tokens)) + "\n";
    }
    const tokenizeAndSnapshotMs = performance.now() - snapshotStarted;
    fs.writeFileSync(snapshotPath, snapshot);
    console.log(JSON.stringify({ engine: "vscode-textmate", node: process.version,
      scope, input: sourcePath, lines: lines.length, rawTokens, warmups,
      loadAndCompileMs, tokenizeMs, tokenizeAndSnapshotMs }));
  } finally {
    registry.dispose();
  }
}

main().catch(error => { console.error(error); process.exitCode = 1; });
