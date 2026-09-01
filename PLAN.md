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
- JSON and XML plist themes with TextMate scope-path specificity and deterministic color maps.
- Theme-aware `tokenizeLine2` packed metadata, variable-font spans, grammar configuration, and
  state-stack diff transport.
- Deterministic termination for malformed zero-width grammar loops.

Theme parsing and binary metadata are additive compatibility layers; they do not change the plain
scope-token shape or make theme configuration mandatory.

## Public API Direction

The root `matter` module will re-export a narrow API built around these concepts:

- `RawGrammar` and `RawRule`: parsed TextMate grammar data.
- `parseRawGrammar(content, filePath)`: parse JSON or XML plist grammar text.
- `RawTheme`, `parseRawTheme`, and `newTheme`: parse and resolve JSON or XML plist themes.
- `Registry`: owns raw grammars, injection registrations, and the current theme.
- `addGrammar`, `setTheme`, and `loadGrammar`: register grammars, replace themes, and compile plain
  or configured grammars by scope name.
- `Grammar`: compiled tokenizer handle.
- `GrammarConfiguration`: initial/embedded languages, token-type overrides, and bracket selectors.
- `StateStack`: immutable cross-line tokenizer state; `nil` means the initial state.
- `StackDiff`: a reference-identity state suffix produced and applied by the stack-diff helpers.
- `Token`: half-open byte offsets and the active scope path.
- `TokenizeLineResult`: tokens, variable-font spans, next state, and an early-stop flag.
- `TokenizeLineResult2`: alternating `uint32` byte offsets and encoded metadata plus fonts/state.
- `tokenizeLine(grammar, line, previousState, timeLimitMs)`: tokenize one line.
- `tokenizeLine2(grammar, line, previousState, timeLimitMs)`: tokenize and resolve binary metadata.
- `EncodedTokenAttributes` accessors: decode language, token type, brackets, style, and color IDs.

Offsets are UTF-8 byte offsets, matching Nim string indexing and `reni`. Missing required grammars,
invalid grammar shapes, and invalid regular expressions raise one of Matter's exported catchable
errors instead of returning silent defaults.

## Module Boundaries

- `src/matter/rawgrammar.nim`: raw types plus JSON/XML-plist parsing and validation.
- `src/matter/selectors.nim`: TextMate scope-selector parsing and matching.
- `src/matter/engine.nim`: registry, include resolution, rule compilation, state, captures, and
  incremental tokenization.
- `src/matter/theme.nim`: raw JSON/plist theme parsing, rule resolution, scope-path matching,
  font attributes, and color-map ownership.
- `src/matter/metadata.nim`: the stable 32-bit token metadata layout and field accessors.
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
- [x] Emit reference-compatible half-open token boundaries and exclude the synthetic newline.
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

#### Phase 5A — Theme model, readers, and lookup

- [x] Define raw theme settings, resolved style attributes, font styles, and `ThemeError`.
- [x] Parse JSON themes and XML plist `.tmTheme` files through `parseRawTheme`.
- [x] Resolve defaults, inherited fields, comma/array scopes, parent scopes, and `>` child
  combinators using `vscode-textmate`'s specificity ordering.
- [x] Build deterministic color IDs, validate the supported hex forms, and support an optional
  frozen caller-provided color map.
- [x] Add curated theme parser and matcher conformance tests.

Exit criterion: equivalent JSON/plist settings resolve to the same defaults, color map, and style
attributes for representative scope paths.

#### Phase 5B — Encoded metadata and grammar configuration

- [x] Define `StandardTokenType` plus the public 32-bit metadata type and field accessors, using
  the `FontStyle` flags from the theme module.
- [x] Match the reference bit layout exactly: language 8 bits, token type 2 bits, balanced bracket
  1 bit, font style 4 bits, foreground 9 bits, and background 8 bits.
- [x] Add grammar configuration for an initial language, embedded-language scopes, token-type
  selector overrides, and balanced/unbalanced bracket selectors.
- [x] Test field replacement, unsigned high-bit behavior, scope-prefix precedence, selector
  ordering, and the reference metadata constants.

Exit criterion: packed values and every decoded field match curated `vscode-textmate` vectors.

#### Phase 5C — Binary tokenization and state transport

- [x] Let registries own and replace a resolved theme and expose its color map.
- [x] Add configured grammar loading without changing the existing plain `loadGrammar` behavior.
- [x] Add `tokenizeLine2`, returning alternating `uint32` start offsets and metadata while
  coalescing adjacent equal metadata and preserving UTF-8 byte offsets.
- [x] Return coalesced variable-font spans from plain and binary tokenization.
- [x] Implement reference-equality state-stack diffs and deterministic application of those diffs.
- [x] Compare multiline theme, embedded-language, token-type override, bracket, and stack-diff
  outputs with curated `vscode-textmate` cases.

Exit criterion: themed multiline fixtures produce reference-compatible packed tokens, fonts, state
transitions, and applied stack diffs in debug, release, and danger modes.

This phase extends the stable plain tokenizer without changing the shape of its scope tokens.

### Phase 6 — Expanded upstream conformance

#### Phase 6A — Matcher and metadata vectors

- [x] Port all 27 cases from `src/tests/matcher.test.ts` with one-to-one case names and expected
  results.
- [x] Port the 9 enabled encoded-metadata cases from `src/tests/grammar.test.ts`.
- [x] Port the 2 enabled font-span cases from `src/tests/grammar.test.ts`.
- [x] Record the upstream source file and pinned commit beside each conformance suite.

Exit criterion: all 38 matcher, metadata, and font cases pass with the same expected values as the
pinned `vscode-textmate` checkout.

#### Phase 6B — Begin/while tokenization fixtures

- [x] Port all 9 cases from `test-cases/suite1/whileTests.json` and its repository-owned grammar
  fixture.
- [x] Preserve the upstream expected token text, scope paths, and cross-line state transitions.
- [x] Keep the fixture self-contained so tests never read from ignored `deps/` or access the
  network.
- [x] Preserve plain tokenizer emission boundaries while continuing to coalesce binary metadata
  and font spans where the reference does.

Exit criterion: the 9 begin/while cases pass from a clean checkout in debug, release, and danger
modes.

#### Phase 6C — Broader fixture corpus

- [ ] Select the next portable tokenizer and theme fixture tranche based on unsupported-feature
  coverage rather than duplicating existing Matter-only regressions.
- [ ] Track ported upstream cases separately from Matter-specific tests so coverage counts remain
  auditable.

Exit criterion: the next fixture tranche has explicit provenance, exact expected output, and no
runtime dependency on the reference checkout.

### Phase 7 — Downloadable grammar catalog

- [x] Publish pinned Open VSX metadata for the Nim/Nimble, C/C++, and Python grammar packages.
- [x] Provide deterministic metadata and versioned VSIX URL construction without downloading.

Exit criterion: callers can select a known grammar package and form its direct Open VSX URLs
without a Node.js or network dependency.

### Phase 8 — Reproducible Moe grammar archive catalog

- [x] Record the 35 `SourceLanguage` modes from Moe commit
  `0dcc33b87cf672e727c54d39b48bd81cc68e6c2c` and map each to an imported TextMate scope.
- [x] Pin source package/version/license/repository/direct VSIX URL and source SHA-256 metadata.
- [x] Bundle allowlisted primary and same-package support grammars as deterministic ordinary
  `ZIP_STORED` archives under `data/grammars/`, retaining manifest, license, and provenance.
- [x] Generate the public Nim catalog and archive notices from one source manifest, without npm.
- [x] Add online regeneration and offline archive verification tasks, including checksum, member,
  license, scope, and Matter parsing coverage.

Exit criterion: a clean checkout can verify all bundled archives offline, while an intentional
manifest update can reproducibly rebuild the same archives after pinned source downloads validate.

### Phase 9 — GitHub release grammar assets

- [x] Add a metadata-only Nim module that embeds the generated grammar catalog with `staticRead`
  and exposes every packaged ZIP as a typed release asset.
- [x] Provide deterministic helpers for exact-tag and latest GitHub release URLs, plus each
  package's pinned upstream VSIX URL.
- [x] Add offline tests for catalog coverage, checksums, URL escaping, and public root-module
  exports.
- [x] Add a Linux tag workflow that verifies and tests Matter, creates the GitHub release, and
  uploads every `data/grammars/*.zip` asset.
- [x] Document the release-tag convention and metadata-only download selection API.

Exit criterion: pushing a Matter release tag publishes all verified grammar ZIPs, and callers can
choose a Matter release archive or its pinned upstream source without performing metadata I/O.

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
