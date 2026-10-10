// Generate visible UTF-8 token snapshots with the VS Code reference engine.
// See tests/fixtures/{css,html,markdown}/README.md for installation and invocation.
const fs = require("fs");
const path = require("path");
const textmate = require("vscode-textmate");
const oniguruma = require("vscode-oniguruma");

function removeRuntimeDispatch(grammar) {
  // Matter's runtime fence dispatch is not a TextMate feature. Leave the
  // upstream static/fallback fence rules available to the reference engine.
  const dispatchIncludes = new Set(Object.entries(grammar.repository || {})
    .filter(([, rule]) => rule.matterEmbeddedLanguage)
    .map(([name]) => "#" + name));
  function visit(value) {
    if (!value || typeof value !== "object") return;
    for (const [key, child] of Object.entries(value)) {
      if (Array.isArray(child)) {
        value[key] = child.filter(rule => !rule?.matterEmbeddedLanguage &&
          !dispatchIncludes.has(rule?.include));
        value[key].forEach(visit);
      } else {
        visit(child);
      }
    }
  }
  visit(grammar);
  return grammar;
}

function readGrammars(grammarDir) {
  const grammars = new Map();
  for (const file of fs.readdirSync(grammarDir)) {
    if (/\.tmLanguage(?:\.json)?$/.test(file)) {
      const raw = textmate.parseRawGrammar(
        fs.readFileSync(path.join(grammarDir, file), "utf8"), file
      );
      grammars.set(raw.scopeName, removeRuntimeDispatch(raw));
    }
  }
  return grammars;
}

async function createRegistry(grammars) {
  await oniguruma.loadWASM(
    fs.readFileSync(require.resolve("vscode-oniguruma/release/onig.wasm")).buffer
  );
  return new textmate.Registry({
    onigLib: Promise.resolve({
      createOnigScanner: patterns => new oniguruma.OnigScanner(patterns),
      createOnigString: text => new oniguruma.OnigString(text)
    }),
    loadGrammar: async scopeName => grammars.get(scopeName) || null
  });
}

function visibleTokens(line, tokens) {
  // Matter uses UTF-8 offsets and excludes the synthetic terminal newline.
  return tokens.map(token => ({
    startIndex: Buffer.byteLength(line.slice(0, Math.min(token.startIndex, line.length))),
    endIndex: Buffer.byteLength(line.slice(0, Math.min(token.endIndex, line.length))),
    scopes: token.scopes
  })).filter(token => token.endIndex > token.startIndex);
}

async function main() {
  const [grammarDir, scope, sourcePath, outputPath] = process.argv.slice(2);
  if (!outputPath) {
    throw new Error("Usage: reference_tokens.cjs grammarDir scope sourcePath outputPath");
  }
  const registry = await createRegistry(readGrammars(grammarDir));
  try {
    const grammar = await registry.loadGrammar(scope);
    if (!grammar) throw new Error("Missing grammar: " + scope);
    let state = textmate.INITIAL;
    const snapshots = [];
    for (const line of fs.readFileSync(sourcePath, "utf8").split(/\r?\n/)) {
      const parsed = grammar.tokenizeLine(line, state);
      state = parsed.ruleStack;
      snapshots.push(visibleTokens(line, parsed.tokens));
    }
    fs.writeFileSync(outputPath, snapshots.map(line => JSON.stringify(line)).join("\n") + "\n");
  } finally {
    registry.dispose();
  }
}

module.exports = { readGrammars, createRegistry, visibleTokens };

if (require.main === module) {
  main().catch(error => {
    console.error(error);
    process.exitCode = 1;
  });
}
