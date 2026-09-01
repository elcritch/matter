# Matter TextMate Engine Port Plan

## Objective

Port the scope-tokenization parts of `microsoft/vscode-textmate` to idiomatic Nim while keeping
Matter's public API small, synchronous, and suitable for native applications. The reference
checkout is `deps/vscode-textmate` at commit `fbe49961ab8077e587fdf5282019655ae69e5f9e`.

Matter uses the MIT-licensed `reni` package for Oniguruma-compatible regular expressions, pinned
at commit `ae88f24359f7d0742328b7e4f538241d6af00fcc`. The TypeScript source is a behavioral
reference, not a runtime dependency or a source file copied into releases.

## Compatibility Target

The first complete port milestone must support:

- JSON and XML plist `.tmLanguage` grammars.
- `match`, `begin`/`end`, and `begin`/`while` rules.
- `captures`, `beginCaptures`, `endCaptures`, and `whileCaptures`.
- Capture retokenization through nested `patterns`.
- Local includes (`#name`), `$self`, `$base`, external grammar includes, and external repository
  includes (`scope.name#rule`).
- Incremental line tokenization with an immutable state stack.
- Dynamic scope names and end/while expressions using capture substitutions.
- Grammar injections and TextMate scope selectors.
- Plain scope tokens compatible with the shape of `vscode-textmate`'s `tokenizeLine` result.
- Deterministic termination for malformed zero-width grammar loops.

Theme parsing and binary metadata tokens are a later compatibility layer. They must not complicate
or leak into the plain scope-token API.

## Public API Direction

The root `matter` module will re-export a narrow API built around these concepts:

- `RawGrammar` and `RawRule`: parsed TextMate grammar data.
- `parseRawGrammar(content, filePath)`: parse JSON or XML plist grammar text.
- `Registry`: owns raw grammars and injection registrations.
- `addGrammar` and `loadGrammar`: register and compile grammars by scope name.
- `Grammar`: compiled tokenizer handle.
- `StateStack`: immutable cross-line tokenizer state; `nil` means the initial state.
- `Token`: half-open byte offsets and the active scope path.
- `TokenizeLineResult`: tokens, next state, and an early-stop flag.
- `tokenizeLine(grammar, line, previousState, timeLimitMs)`: tokenize one line.

Offsets are UTF-8 byte offsets, matching Nim string indexing and `reni`. Missing required grammars,
invalid grammar shapes, and invalid regular expressions raise one of Matter's exported catchable
errors instead of returning silent defaults.

## Module Boundaries

- `src/matter/rawgrammar.nim`: raw types plus JSON/XML-plist parsing and validation.
- `src/matter/selectors.nim`: TextMate scope-selector parsing and matching.
- `src/matter/engine.nim`: registry, include resolution, rule compilation, state, captures, and
  incremental tokenization.
- `src/matter.nim`: package documentation and stable re-exports only.

Implementation helpers stay private unless another module genuinely requires them.

## Phases

### Phase 0 — Reference and dependency baseline

- [x] Clone `microsoft/vscode-textmate` under ignored `deps/` for local reference.
- [x] Record the exact reference commit in this plan.
- [x] Add `reni` through Atlas and verify Atlas-generated paths.
- [x] Replace the template README/API/test before the first milestone is complete.

### Phase 1 — Raw grammar model and readers

- [x] Define recursive raw grammar, rule, repository, and capture types.
- [x] Parse and validate JSON `.tmLanguage.json` input.
- [x] Parse XML plist `.tmLanguage` input without accepting unsafe external entities.
- [x] Preserve field-presence distinctions needed for capture fallback behavior.
- [x] Add focused tests for valid input and malformed roots, rules, captures, and plist values.

Exit criterion: the same semantic `RawGrammar` is produced from equivalent JSON and plist fixtures.

### Phase 2 — Selectors, registry, and include compilation

- [x] Parse selector alternatives, exclusions, grouping, and `L:`/`R:` priorities.
- [x] Match selectors against ordered scope paths.
- [x] Register grammars and declared injection scope names.
- [x] Resolve local, self, base, external, and external-repository includes.
- [x] Compile recursive rule graphs deterministically without looping on recursive includes.
- [x] Translate regex compilation failures into contextual Matter errors.

Exit criterion: representative recursive and cross-grammar repositories compile and selector tests
match the `vscode-textmate` behavior used by injections.

### Phase 3 — Incremental tokenizer

- [x] Implement earliest-match and rule-order precedence.
- [x] Implement `match`, `begin`/`end`, and `begin`/`while` state transitions.
- [x] Carry immutable state between lines.
- [x] Apply capture scopes, dynamic names, end backreferences, and nested retokenization.
- [x] Emit coalesced half-open tokens and exclude the synthetic newline.
- [x] Detect zero-width non-progress loops and honor an optional time limit.
- [x] Apply matching injections with left/right priority.

Exit criterion: multiline, nested-capture, backreference, include, while, and injection fixtures
produce the expected tokens and next-line state.

### Phase 4 — Public package and conformance suite

- [x] Replace the template root module with documented re-exports.
- [x] Add README setup, parsing, registry, and line-tokenization examples.
- [x] Port a curated set of MIT-compatible `vscode-textmate` fixtures into repository-owned tests.
- [x] Add regression tests for malformed and adversarial grammars.
- [x] Run debug, release, and danger tests and format all touched Nim files with `nph`.

Exit criterion: `atlas-run tests` passes in all three modes and the README example compiles.

### Phase 5 — Theme and binary-token compatibility

- [ ] Parse raw TextMate themes and scope settings.
- [ ] Implement selector-based theme lookup and color maps.
- [ ] Add standard token type, embedded-language, font-style, and bracket metadata.
- [ ] Implement `tokenizeLine2`-style packed tokens and state-stack diff helpers.
- [ ] Compare curated theme outputs with `vscode-textmate`.

This phase extends the engine after plain scope tokenization is stable; it does not block the first
usable release.

## Verification Matrix

Every completed phase is checked with deterministic local tests. The milestone verification is:

```sh
atlas install
atlas-run tests
atlas-run tests -- -d:release
atlas-run tests -- -d:danger
```

No test may fetch grammars or access the network. Reference fixtures under `deps/` are never needed
to build or test a clean checkout.

## Licensing and Distribution

Matter and `vscode-textmate` are MIT-licensed. Any fixture brought into `tests/` must have a
compatible license and retain required attribution. Individual third-party grammar files are not
redistributed merely because they are present in the ignored reference checkout.
