# Required surfaces & roadmap

> What exists is a set of *capabilities*. To make them land in real workflows
> they need *surfaces* — the entry points, packaging, and integrations that put
> a capability where the work happens. This is the gap analysis.

## What exists today

Capabilities (all built, verified): `--debug` (#line stepping + native
`Exception#backtrace`), multi-file source maps, value-bisect (differential
localization) + triage, `--emit-rbs`, `--emit-types`, a ruby-lsp hover addon.

What they lack is reach: most are raw CLIs or a single editor feature, the
compiler half is on a fork, and nothing yet runs unattended in CI or a gem's
`verified` pipeline.

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

1. **Container / bigint value formatting** — arrays, hashes, and Bignums are the
   biggest gap (skipped today). Bignum via `sp_bigint_to_s`; containers via the
   runtime `sp_json_*` helpers. Unlocks localizing the array/hash-shaped
   miscompiles (e.g. version-compare bugs).
2. **Per-method variable scoping** — key locals by `(method, var)` not just
   `(file, var)`, so same-named locals in different methods of one file don't
   merge. Needs a stable Spinel↔CRuby method-name mapping (mangling-aware).
3. **`caller`** — the runtime `sp_caller_now()` is built; it needs a codegen
   dispatch site (`Kernel#caller` is currently unsupported).

### F. Packaging & upstreaming

1. **PRs to `matz/spinel`** for the compiler surfaces — they're gated and the
   bootstrap fixpoint holds; the open question is API shape (flag names,
   `node_*` fields), worth settling on real apps first.
2. **Ship the tools.** `tools/value-bisect` as a `spinel-tools` gem/CLI;
   `tools/ruby-lsp-spinel` published (or path-installed via the project Gemfile).
3. **Validate at scale.** Run the whole battery on `tep` and `toy` (multi-file,
   thousands of lines) — the real test of the multi-file maps, the harness, and
   the LSP, and the evidence to bring upstream.

## Suggested order

The cheapest leverage is **A1–A2** (`make triage`, `spinel doctor`) and the
**E1** harness depth (containers/bigint) — they multiply the value of what's
already built, for agents and gem authors, with no new research. Then **C3** (the
DAP) for IDE users, and **F1/F3** (upstream + validate on `tep`/`toy`) to make it
real. **B** and the rest of **C/D** are polish that follows once the core is
landing.

## Cross-references

- [03-tooling-for-contributors-and-agents.md](03-tooling-for-contributors-and-agents.md) — the operator's manual + proof-of-value.
- [04-tooling-for-developers.md](04-tooling-for-developers.md) — the app/gem-author how-to.
- `tools/value-bisect/README.md`, `tools/ruby-lsp-spinel/README.md` — per-tool detail.
