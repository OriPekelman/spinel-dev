# Packaging proposal — how the tools ship

> Status: **proposal, not published.** We don't cut releases until the compiler
> surfaces the tools depend on (`--debug`, `--emit-rbs`, `--emit-types`, native
> backtrace) land in `matz/spinel` — publishing now would pin users to the
> `feat/typing` fork and to a flag/JSON API that may change in review. This doc
> fixes the *boundaries* so the split is concrete and consumers (e.g. spinelgems'
> Localizer) can target stable names.

## Principle: compiler features upstream, harness as gems

Two layers, two destinations:

- **Compiler features → `matz/spinel`** (not gems): `--debug`/`#line` stepping,
  `--emit-rbs`, `--emit-types`, native `Exception#backtrace`. These are
  observability hooks *inside* the compiler; they belong upstream, opt-in and
  output-neutral. (Roadmap F1 — underway: `--emit-rbs` merged in
  matz/spinel#1276, `--debug` in review #1292.)
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

1. Upstream merge of the compiler surfaces into `matz/spinel` (F1) — until then
   we'd pin users to the fork.
2. The `--emit-types` JSON shape + flag names may change in review ("settle the
   API on real apps first").
3. The `spinel-engine` resolver decision (shared micro-gem vs. duplicated
   env-var contract).

## Status — scaffolded, not yet published

The upstream API is settling (`--emit-rbs` + `--debug` merged, `--emit-types` in
review), so the gemspecs are now **scaffolded and `gem build`-clean**:

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
