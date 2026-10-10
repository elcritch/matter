# Markdown profiling results

Measured on an Apple M3 Pro, macOS ARM64, Nim 2.2.12, `atomicArc`, threads enabled,
with release builds that reuse a compiled grammar and start each document
with fresh state. Package loading and compilation are excluded from document
timings; JSON token serialization is included.

| Input | Lines | Tokens | Complete document | Slowest line | Reference CRC32 |
| --- | ---: | ---: | ---: | ---: | --- |
| Merenda, before native Reni integration | 576 | 1,745 | 192.5–193.5 ms | 1.2 ms | `3C62BA15` |
| Feature coverage, before native Reni integration | 72 | 309 | 13.6–14.2 ms | 2.1 ms | `9CE9F590` |
| Merenda, with native Reni integration | 576 | 1,745 | 140.4–142.0 ms | 0.8 ms | `3C62BA15` |

The first two rows use three unlimited passes on Reni
`7703aa83d8bbd358872bbab388b2c62e6798b88a` (upstream HEAD checked on 2026-10-11).
With a 100 ms per-line budget, that implementation took 192.7 ms for Merenda
and 14.3 ms for features. The final row uses three passes with the same budget
on the named fork branch `elcritch/reni#feat/textmate-compat`, measured at
`97b95d2`; the dependency is pinned to the branch name.

Every measured pass completes with zero interrupted lines and an identical
reference snapshot. The per-regex step cap remains 10,000. Loading the Markdown
package, its available transitive grammars, and compiling it takes approximately
280–290 ms. All scope snapshots also pass with the new dependency.

## Profiling and changes

The first correctness-preserving Markdown measurement took approximately
762 ms for the Merenda fixture. Native sampling placed a large part of rule
probing inside regex parsing/compilation: disabled `\A`/`\G` variants were being
recompiled repeatedly. Precompiling immutable anchor variants and sharing
identical regex sources reduced this to approximately 360 ms.

The next native sample exposed copying of Reni's compiled regex sequences while
selecting those variants. Matter now borrows the selected immutable value for
each probe. `--expandArc:findRuleRegex` confirms the regex copy and destructor
are eliminated. This brought the fixture to approximately 193 ms.

The HTML profile then found repeated compilation of end/while expressions.
Sharing immutable expressions without begin-capture references, together with
native Reni capture/anchor options, reduced Markdown to approximately 141 ms:
27% less time than the preceding 193 ms result and about 5.4× faster than the
corrected 762 ms implementation. Expressions depending on begin captures remain
resolved per opening match. Matching and rule traversal dominate the remaining
profile.

Earlier broken output produced only 634 tokens and appeared faster. It is not
a valid performance baseline: missing scopes and leaked state discarded much
of the highlighting work. Timings above use complete reference-compatible
output.

## Compatibility findings

Reference comparisons exposed these defects, now covered by both full snapshots
and focused regression tests:

- Reni's default named-group mode drops ordinary capture groups. The native
  `rfCaptureGroup` option now preserves mixed capture indices, restoring link
  targets, images, punctuation, and other Markdown classes.
- `^` must reject the empty position after a terminal newline, while `$` can
  match EOF there. Reni now follows that distinction. Matter also scans EOF
  after a fence begin consumes the synthetic LF, allowing a zero-width embedded
  continuation to open for the next line. Focused tests protect both behaviors.
- A failed nested `while` discarded the successful enclosing rule's `\G`
  anchor. Preserving it restores following nested Markdown constructs.
- Mid-line `(^|\G)` matches retain their original search origin. The former
  extra anchored probe is removed: native Reni handles the reduced case
  correctly, and Matter's EOF continuation fix resolves the fence scope issue.
- Lookahead captures extending past the whole match were discarded. Keeping
  them restores fence language classes; emitted token ranges remain disjoint.

The test also verifies all six heading classes and all four public theme font
styles. HTML, CSS, YAML front matter, lists, fences, and subsequent Markdown
retain the same visible token ranges and scope paths as the reference engine.
Unknown fenced languages retain Markdown's block scopes; loading an additional
registered grammar enables its embedded scopes through runtime dispatch.

## Reni integration

[Upstream Reni PR #84](https://github.com/fox0430/reni/pull/84) supplies native
capture mode and per-search `\A`/`\G` disabling options corresponding to
Oniguruma options, plus the terminal-newline `^` correction. Matter uses these
APIs directly. Numeric references to duplicate capture names are supported;
private capture-name rewriting and four compiled anchor variants are removed.

TextMate's `\z` treatment remains in Matter's adapter, preserving normal Reni
end-of-input semantics. No multi-pattern scanner or global mutable cache was
introduced. The named fork dependency can return to upstream after the native
APIs are merged and available there.
