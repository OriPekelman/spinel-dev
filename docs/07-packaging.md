# Packaging proposal — how the tools ship

> Status: **proposal, gemspecs scaffolded & `gem build`-clean, not yet
> published.** The compiler surfaces the tools depend on (`--debug`, `--emit-rbs`,
> `--emit-types`, native backtrace) have **now merged into `matz/spinel`**, so the
> upstream gate is cleared — a release can target upstream rather than the
> `feat/typing` fork. The remaining gates are the `spinel-engine` resolver
> decision and freezing the `--emit-types` JSON shape. This doc fixes the
> *boundaries* so the split is concrete and consumers (e.g. spinelgems' Localizer)
> can target stable names.

## Principle: compiler features upstream, harness as gems

Two layers, two destinations:

- **Compiler features → `matz/spinel`** (not gems): `--debug`/`#line` stepping,
  `--emit-rbs`, `--emit-types`, native `Exception#backtrace`. These are
  observability hooks *inside* the compiler; they belong upstream, opt-in and
  output-neutral. (Roadmap F1 — **all merged**: `--emit-rbs` #1276, `--debug`
  #1292, `--emit-types` #1298, native backtrace #1300, FloatArray ops #1301.)
- **Harness → gems**: the tools that *consume* those hooks — the LSP addon, the
  differential bisector, the one-shot doctor. These are what we package.

So packaging is entangled with upstreaming: the gems get smaller and cleaner as
more of the compiler half merges, because they stop carrying fork-specific glue.

## Proposed split — three small gems, not one

Driven by **who consumes what** (different audiences/deps → separate gems):

### 1. `ruby-lsp-spinel` (already scaffolded)
- The ruby-lsp addon: inferred types on hover + degrade warnings.
- Pure Ruby. Dep: `ruby-lsp >= 0.23`. Runtime: a `spinel` that supports
  `--emit-types`.
- Audience: editor users. Nothing else should drag in `ruby-lsp`.
- Already has a gemspec (`tools/ruby-lsp-spinel/`). Publishable first, once
  `--emit-types` is upstream and its JSON shape is frozen.

### 2. `spinel-bisect`
- The differential value-bisection harness: `bisect.sh`, `compare.py`,
  `cruby_trace.rb`, `spinel_lldb_trace.py`, `triage.sh`.
- **Polyglot by necessity**: the lldb trace must be Python (lldb's scripting API
  is Python-only), so this gem is *not* pure Ruby — it ships the scripts as gem
  data with thin `exe/` wrappers (`spinel-bisect`, `spinel-triage`) that locate
  them via `__dir__`. Runtime prereqs: `python3`, `lldb`, a `spinel` checkout.
- Audience: anyone localizing a miscompile. Crucially, **spinelgems' `Localizer`
  should depend on this gem** — a gem install gives it a stable path, replacing
  the `SPINEL_BISECT` › sibling-checkout › `~/sites/spinel-dev` probing
  (spinelgems#11).

### 3. `spinel-doctor`
- The one-shot health check (compile-probe + degrade scan + optional bisect).
- Thin: `doctor.sh` + an `exe/spinel-doctor`. Dep: **`spinel-bisect`** (for the
  behavior leg) + a `spinel` checkout.
- Kept separate from `spinel-bisect` precisely so consumers who want *only* the
  bisector (spinelgems) don't pull doctor's orchestration. doctor is the
  opinionated front-end; bisect is the engine.
- **Re-scope (2026-06).** Upstream matz/spinel now ships a **first-party
  `spinel-doctor`** (we contributed matz#1476/#1482), so the one-shot health
  check is owned upstream. spinel-dev shouldn't re-ship a competing
  `spinel-doctor` name; this layer's distinct value is the **differential
  bisector** (`spinel-bisect`) plus the migration/perf tooling on top of the
  upstream doctor — not a parallel one-shot. Package accordingly: keep
  `spinel-bisect` as the engine and let the upstream tool own the front-end.

## Cross-cutting concerns

- **Engine resolution.** All tools locate the compiler via `SPINEL_DIR` (default
  `~/sites/spinel`). bundler-spinel already has a richer resolver (`SPINEL_DIR` ›
  `~/.cache/spinel/current` › `PATH`). Rather than duplicate, factor a tiny
  **`spinel-engine`** resolver that both bundler-spinel and these tools depend
  on. (Optional 4th micro-gem; until then, keep the env-var contract identical
  across tools so they're swappable.)
- **Polyglot reality.** `spinel-bisect` can't be pure Ruby (lldb→Python). We
  *could* rewrite `compare.py`/`cruby_trace.rb` in Ruby, but `spinel_lldb_trace.py`
  stays. Accept it; declare `python3`/`lldb` as runtime prerequisites in the gem
  description and fail fast with a clear message when absent.
- **Versioning against a moving target.** The debug/emit surfaces are pre-upstream
  and still changing. Like bundler-spinel's ledger, key compatibility on the
  spinel **revision**, and don't publish until the upstream API (flag names,
  `--emit-types` JSON schema) stabilizes through review.

## What blocks publishing (the gate)

1. ~~Upstream merge of the compiler surfaces into `matz/spinel` (F1)~~ —
   **done**: all five surfaces merged (#1276/#1292/#1298/#1300/#1301), so a
   release can target upstream `spinel` rather than the fork.
2. The `--emit-types` JSON shape + flag names are now settled (merged in #1298) —
   the "settle the API on real apps first" gate is cleared.
3. The `spinel-engine` resolver decision (shared micro-gem vs. duplicated
   env-var contract).

## Status — scaffolded, not yet published

The upstream API has **landed** (`--emit-rbs`, `--debug`, `--emit-types`, native
backtrace, FloatArray ops all merged), so the gemspecs are **scaffolded and
`gem build`-clean** and the upstream-merge gate is no longer blocking:

- `tools/ruby-lsp-spinel/ruby-lsp-spinel.gemspec` (pure Ruby; dep `ruby-lsp`).
- `tools/value-bisect/spinel-bisect.gemspec` + `exe/spinel-bisect`,
  `exe/spinel-triage` — ships the sh/python/ruby scripts as gem data; the exe
  launchers `exec` them. Runtime prereqs declared in the description (a `spinel`
  checkout, `python3`, `lldb`).
- `tools/doctor/spinel-doctor.gemspec` + `exe/spinel-doctor` — depends on
  `spinel-bisect` for the behavior leg.

```sh
cd tools/value-bisect && gem build spinel-bisect.gemspec     # -> spinel-bisect-0.1.0.gem
```

**Not published.** Publish order when ready: `ruby-lsp-spinel` first (most
self-contained, once `--emit-types` lands), then `spinel-bisect` → `spinel-doctor`.
Still open before a push: the shared `spinel-engine` resolver decision and pinning
the `--emit-types` JSON shape (its PR invites that). `gem build` artifacts are
gitignored.
