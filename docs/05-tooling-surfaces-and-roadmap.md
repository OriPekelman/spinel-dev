# Required surfaces & roadmap

> What exists is a set of *capabilities*. To make them land in real workflows
> they need *surfaces* — the entry points, packaging, and integrations that put
> a capability where the work happens. This is the gap analysis.

## What exists today

Capabilities (all built, verified): `--debug` (#line stepping + native
`Exception#backtrace`, macOS + Linux + a debug null-receiver guard), multi-file
source maps, value-bisect (differential localization — scalars, strings,
containers, bignums, Rational, plus an output-diff fallback and a single-sided
`--no-cruby` mode) + triage, `--emit-rbs`, `--emit-types`, `spinel doctor`, a
ruby-lsp hover addon, and a daily rebase-and-verify routine keeping the fork
current on upstream.

## Shipped since this gap-analysis was written

- **A1** `make triage`, **A2** `spinel doctor`, **A3** `bisect.sh --json`,
  **A4** spinelgems `verify` self-localization — all done.
- **E1** container / bignum value formatting (+ Rational + the output-diff
  fallback) — done; plus the single-sided `--no-cruby` harness mode.
- **F1** upstreaming **complete** — all five surfaces merged: `--emit-rbs`
  (matz/spinel#1276), `--debug` (#1292), `--emit-types` (#1298), native
  backtrace (#1300), FloatArray ops (#1301).
- **F3** validated at scale on `tep` and `toy` — see
  [06-validation-results](06-validation-results.md).

The gaps that remain are the interactive (**B**) and IDE/DAP (**C**) surfaces,
type-checker wiring (**D**), and the rest of harness depth (**E2/E3**).

## Surfaces, by where the work happens

### A. Non-interactive terminal (CI, agents, scripts) — *highest leverage*

This is where Spinel is actually developed (agents) and where gems get gated.

1. **`make triage` target** — `make test` then `triage.sh --failing`, emitting a
   machine block per failure. Lowest-effort, highest-value: turns the suite from
   pass/fail into pass/fail/**where**. (triage.sh + VERDICT lines exist; this is
   ~10 lines of Makefile.)
2. **`spinel doctor app.rb`** — one command running the whole battery: compile
   probe (`-c`, scrape `cannot resolve`), `--emit-rbs` degrade scan (count/locate
   `untyped`), and `bisect.sh` if an oracle smoke exists. Emits a single report
   (human + `--json`). This is the "tell me everything risky about this program"
   entry point an agent or CI wants.
3. **`--json` everywhere.** `bisect.sh` should emit the structured finding (not
   just the `VERDICT|` line); `--emit-types` is already JSON; `--emit-rbs` could
   emit a companion `.degrade.json`. Uniform JSON = trivial agent/CI consumption.
4. **spinelgems `verified` integration.** When the differential smoke diverges,
   `spinel-compat verify` currently reports `L2 cruby=… spinel=…`. Have it call
   `bisect.sh` to upgrade that to a variable+line. The `verified` rung becomes
   self-localizing.

### B. Interactive terminal

1. **`spinel debug app.rb`** — compile `--debug` and drop into lldb pre-configured
   for Ruby: breakpoints by `.rb:line`, an `lv_`-aware frame printer, the source
   map loaded. Removes the raw-lldb friction in
   [04-tooling-for-developers.md](04-tooling-for-developers.md).
2. **`spinel explain app.rb:LINE`** — print the inferred type(s) at that position
   (`--emit-types` lookup) and the generated C span (the `#line` map, inverted).
   The closed-world answer to "what did the compiler do with this line" — the
   tractable substitute for a REPL, which the architecture rules out.
3. **`spinel lint app.rb`** — the `--emit-types` diagnostics as a plain
   terminal linter (degrade warnings with file:line), no editor required.

### C. IDE / editor

1. **Push diagnostics** (degrade warnings as squiggles). ruby-lsp 0.26 has no
   addon hook for this, so the data rides on hover today. Options: contribute a
   diagnostics extension point upstream, or ship a tiny standalone LSP that only
   publishes the `--emit-types` diagnostics.
2. **Inlay hints** — inferred types inline (`x  ‹Array[Integer]›`). High-value,
   low-noise; ruby-lsp has an inlay-hint addon hook to target next.
3. **A Debug Adapter (DAP)** wrapping lldb + the `#line` map, so VS Code /
   JetBrains can set Ruby-line breakpoints from the gutter and inspect `lv_`
   locals in the variables pane. This is the single biggest IDE unlock — it turns
   `--debug` from a CLI ritual into a normal "press F5" experience.
4. **Code lens / quick-fix** — "degrades to untyped here" with a quick-fix to
   insert an RBS annotation.

### D. Type-checker integration

1. **Steep/Sorbet wiring** — `--emit-rbs` into a `sig/` dir + a `Steepfile`, so the
   inferred signatures are checkable and diffable in CI. The export is
   `rbs validate`-clean; what's missing is the project scaffolding + a per-class
   file layout option.
2. **Round-trip guard** — feed the exported RBS back via `--rbs` and assert
   inference doesn't widen further; drift means an inference regression.

### E. Harness depth

1. ~~**Container / bigint value formatting**~~ — **done.** Arrays, typed hashes,
   bignums, and Rational are now compared (bignum via `sp_bigint_to_s`, float
   arrays + hashes via the runtime `sp_*_inspect`), plus an output-diff fallback
   for divergences that never land in a local. This localized real surveyed gem
   miscompiles (e.g. `abbrev`'s hash-iteration bug).
2. **Per-method variable scoping** — key locals by `(method, var)` not just
   `(file, var)`, so same-named locals in different methods of one file don't
   merge. Needs a stable Spinel↔CRuby method-name mapping (mangling-aware).
3. **`caller`** — the runtime `sp_caller_now()` is built; it needs a codegen
   dispatch site (`Kernel#caller` is currently unsupported).

### F. Packaging & upstreaming

1. **PRs to `matz/spinel`** for the compiler surfaces — **underway**, one
   reviewable PR at a time: `--emit-rbs` merged (#1276), `--debug` in review
   (#1292), `--emit-types` queued, native backtrace + the null-receiver guard
   after. Each is opt-in and output-neutral; the API shape (flag names, JSON
   schema) is being settled in review.
2. **Ship the tools.** `tools/value-bisect` as a `spinel-tools` gem/CLI;
   `tools/ruby-lsp-spinel` published (or path-installed via the project Gemfile).
3. **Validate at scale.** Run the whole battery on `tep` and `toy` (multi-file,
   thousands of lines) — the real test of the multi-file maps, the harness, and
   the LSP, and the evidence to bring upstream.

## Suggested order

The cheap, high-leverage items (**A1–A4**, **E1**, **F1**, **F3**) are **done** —
they multiplied the value of what was already built. What's left, in rough order:
finish the **F1** upstreaming (`--debug` → `--emit-types` → backtrace), then
**C3** (the DAP) for IDE users — the single biggest remaining unlock — with
**B** (interactive `spinel debug/explain/lint`), **D** (Steep/Sorbet wiring), and
**E2/E3** as the follow-on polish.

## Cross-references

- [03-tooling-for-contributors-and-agents.md](03-tooling-for-contributors-and-agents.md) — the operator's manual + proof-of-value.
- [04-tooling-for-developers.md](04-tooling-for-developers.md) — the app/gem-author how-to.
- `tools/value-bisect/README.md`, `tools/ruby-lsp-spinel/README.md` — per-tool detail.
