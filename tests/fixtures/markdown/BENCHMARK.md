# Markdown profiling results

Measured on an Apple M3 Pro, macOS ARM64, Nim 2.2.12, `atomicArc`, threads enabled,
with Reni `7703aa83d8bbd358872bbab388b2c62e6798b88a` (upstream HEAD checked on
2026-10-11). Release builds reuse a compiled grammar and start each document
with fresh state. Package loading and compilation are excluded from document
timings; JSON token serialization is included.

| Input | Lines | Tokens | Complete document | Slowest line | Reference CRC32 |
| --- | ---: | ---: | ---: | ---: | --- |
| Merenda documentation | 576 | 1,745 | 192.5–193.5 ms | 1.2 ms | `3C62BA15` |
| Markdown feature coverage | 72 | 309 | 13.6–14.2 ms | 2.1 ms | `9CE9F590` |

Three unlimited passes produced these ranges. With a 100 ms per-line budget,
the Merenda document took 192.7 ms and the feature fixture 14.3 ms. Both completed
with zero interrupted lines and identical reference snapshots. The per-regex
step cap remains 10,000. Loading the Markdown package, its available transitive
grammars, and compiling it took approximately 280–290 ms.

## Profiling and changes

The first correctness-preserving Markdown measurement took approximately
762 ms for the Merenda fixture. Native sampling placed a large part of rule
probing inside regex parsing/compilation: disabled `\A`/`\G` variants were being
recompiled repeatedly. Precompiling immutable anchor variants and sharing
identical regex sources reduced this to approximately 360 ms.

The next native sample exposed copying of Reni's compiled regex sequences while
selecting those variants. Matter now borrows the selected immutable value for
each probe. `--expandArc:findRuleRegex` confirms the regex copy and destructor
are eliminated. This brought the fixture to approximately 193 ms: about 4×
faster than the corrected 762 ms implementation. The remaining profile includes
rule traversal, match caching, and Reni matching; dynamic end/while expressions
can still require compilation.

Earlier broken output produced only 634 tokens and appeared faster. It is not
a valid performance baseline: missing scopes and leaked state discarded much
of the highlighting work. Timings above use complete reference-compatible
output.

## Compatibility findings

Reference comparisons exposed these defects, now covered by both full snapshots
and focused regression tests:

- Reni's default named-group mode drops ordinary capture groups. Matter adapts
  mixed groups to preserve TextMate's numeric capture indices, restoring link
  targets, images, punctuation, and other Markdown classes.
- Reni can match line anchors at the empty position after a terminal newline.
  Excluding that synthetic position closes Markdown front matter and list
  continuations correctly and prevents fences from consuming the synthetic LF.
- A failed nested `while` discarded the successful enclosing rule's `\G`
  anchor. Preserving it restores following nested Markdown constructs.
- Reni's search hint for `(^|\G)` can skip a valid mid-line `\G` alternative.
  An anchored attempt at the original cursor preserves the expected match.
- Lookahead captures extending past the whole match were discarded. Keeping
  them restores fence language classes; emitted token ranges remain disjoint.

The test also verifies all six heading classes and all four public theme font
styles. HTML, CSS, YAML front matter, lists, fences, and subsequent Markdown
retain the same visible token ranges and scope paths as the reference engine.
Unknown fenced languages retain Markdown's block scopes; loading an additional
registered grammar enables its embedded scopes through runtime dispatch.

## Useful Reni follow-ups

The smallest high-value upstream addition is an explicit capture-group compile
option corresponding to Oniguruma's `ONIG_OPTION_CAPTURE_GROUP`. It should keep
ordinary and named group indices and permit numeric references in that mode.
That would remove most of Matter's source adaptation, including its current
restriction on numeric references to duplicate names.

Native fixes for `(^|\G)` search hints and terminal-newline line anchors would
remove two further workarounds. Search options for a separate `\G` anchor position
and enabling/disabling `\A` would avoid compiling anchor variants. A read-only
compiled-regex handle or documented borrowing examples would help callers avoid
accidental deep copies. A multi-pattern scanner could reduce repeated traversal,
but needs measurement and is a larger API addition.

These are follow-ups, not dependency changes in this benchmark. Any dependency
on the `elcritch/reni` fork should use a named branch, as requested.
