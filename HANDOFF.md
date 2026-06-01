# Session handoff — Spinel debuggability & inference tooling

Continuation point for a Claude Code session **on the gx10**. Everything below is
committed and synced; nothing is in-flight.

## What this is

Tooling that makes the Spinel AOT compiler's behavior and inference observable —
to debug compiled programs, surface inferred types, and catch *silent
miscompiles* (the failure mode spinelgems calls the dangerous one). Two homes:

- **`OriPekelman/spinel`** fork, branch **`feat/typing`** — the compiler changes
  (all opt-in / `--debug`-gated; non-debug output byte-for-byte unchanged).
  On gx10: `~/sites/spinel`, remote `ori`, branch `feat/typing`.
- **`OriPekelman/spinel-dev`** (this repo) — design notes + the standalone tools.
  On gx10: `~/sites/spinel-dev` (gx-synced; `git pull` for the latest).

Read `docs/03/04/05` for the operator's manual, the developer how-to, and the
surfaces roadmap. `MEMORY` of the deeper findings lives in the Mac session, but
the load-bearing one is captured below.

## Done and validated on gx10 (Linux/aarch64, gcc, lldb-18)

All four roadmap items (`docs/01-debuggability.md`) shipped:
1. `spinel --debug` — `#line` stepping + native `Exception#backtrace` (now
   works on **Linux too**, at macOS parity — see Done #1 below).
2. ruby-lsp addon (`tools/ruby-lsp-spinel`) — inferred type on hover + degrade.
3. `spinel --emit-rbs` / `--emit-types` — inference as RBS / position JSON.
4. native backtrace (item above).

Plus the standalone tools, all working on gx10:
- **value-bisect** (`tools/value-bisect/bisect.sh`) — differential value
  localization vs CRuby. `--json` for machine output. Scalars, strings, bigints,
  int/string arrays; crash + abort triage.
- **triage** (`triage.sh --failing`, or `make triage` in the fork) — localize
  every test-suite FAIL/ERR.
- **spinel doctor** (`tools/doctor/doctor.sh`) — one-shot compile-probe +
  inference-degrade scan + behavior check; human or `--json`.

gx10 status: build `make all` ≈ 3:19; `make test` = 706 pass / 0 fail / 0 err.

## THE key finding (load-bearing)

`#line` directives **corrupt the DWARF variable-location info**, so a debugger
reads a function's locals from the wrong stack slot (their zero-init) whenever
the function has a GC-rooted (heap) local. **Cross-toolchain** — reproduced on
both clang/lldb (macOS) and gcc/gdb (gx10). Implications:
- The harness sidesteps it: it traces a `#line`-free build and maps C-lines back
  to Ruby via a map derived from the directives (see `bisect.sh`). So the harness
  is reliable on heap-local programs.
- `spinel --debug` *stepping* still misreads locals in such functions (`p lv_x`
  over corrupt DWARF). Source stepping/line-table is fine; only values are wrong.

## Done this session (gx10, 2026-06-01) — all three prior open items

1. **Native `Exception#backtrace` on Linux** — DONE (fork `feat/typing`,
   commit `7976266`). Three coupled changes, all `--debug`-gated:
   `sp_bt_symbol` now parses the glibc `module(sym+0xoff)` form (empty symbol =
   unresolved → skip) alongside the macOS form; `method_linkage_named` emits user
   methods with **external** linkage in debug (was `static` — `static` symbols
   never reach the dynamic symbol table even under `-rdynamic`); the wrapper
   links debug builds with `-rdynamic` on non-Darwin. Verified: `Foo#bar →
   toplevel → <main>` for a raise; ZeroDivisionError drops the `sp_idiv` runtime
   frame via the denylist; cross-file naming works (`Helper#cls_boom →
   Helper#cls_risky → driver → <main>`). `make test` = 706 pass / 0 fail.
2. **spinelgems `verify` → self-localize** — DONE (spinelgems `main`, commit
   `6ba9533`, **not yet pushed** — default-branch protection; repo was already
   +37 ahead of origin). New `Bundler::Spinel::Localizer` runs `bisect.sh --json`
   on the still-on-disk harness when a smoke diverges and appends
   `localized:<file>:<line> <var> cruby=… spinel=…`. Resolves bisect via
   `SPINEL_BISECT` › sibling spinel-dev › `~/sites/spinel-dev`; `SPINEL_DIR`
   points it at the engine; parses stdout (bisect exits 1 on divergence).
   Verified end-to-end on a `x << 1` overflow gem.
3. **Validate on `tep`** — DONE. `spinel doctor` + `--emit-rbs`/`--emit-types`
   ran on the full multi-file framework (40-file `require_relative` chain).
   Findings below.

## Open next steps (new, from the tep validation + parity gaps)

1. **The differential harness can't run tep-style frameworks.** `lib/tep.rb`
   raises on `require` under CRuby (AOT-only guard), so doctor's *behavior* leg
   and `bisect.sh` (which use CRuby as the oracle) report "harness could not run."
   The *static* legs (compile-probe, inference-degrade, `--emit-rbs`) scale fine.
   Option: a `--no-cruby`/single-sided mode, or document that differential
   localization needs a CRuby-runnable entry (most app code is; the framework
   bootstrap isn't).
2. **Backtrace cosmetics (parity gap, shared with macOS).** Class methods print
   as `Helper#cls_boom` (mangled `sp_<Cls>_cls_<m>`) instead of `Helper.boom`,
   and every frame attributes to the *toplevel* `.rb` (`sp_bt_srcfile` is one
   path, not per-frame). Both are in the shared `sp_bt_symbol`/`sp_bt_format`;
   fixing means a `cls_`-aware splitter + per-frame file from the source map.
3. **tep silent-emit-0 + FFI placeholders (surfaced by the battery).** doctor
   flagged `delete_at` on `float_array` in `Tep::Llm::OpenAI::Backend#
   generate_embeddings` → *unresolved call, silently emits 0* (a real miscompile
   site). Separately, compiling `lib/tep` directly (not via `bin/tep`) leaks the
   `@TEP_PG_CFLAGS@`/`@TEP_*_O@` ffi placeholders to the linker — expected, but a
   reminder the battery should drive tep through `bin/tep`, which substitutes
   them (`spinel-ext.json`). tep inference is healthy: ~26 untyped / 562 methods.

## Build / rebuild notes

- The wrapper prefers the native `spinel_analyze` / `spinel_codegen` binaries;
  after editing those `.rb` files, `make codegen` rebuilds them (gx10 ≈ 3 min).
  `make parse` rebuilds the C parser only.
- The harness uses the Ruby path explicitly, so it reflects `.rb` edits without a
  rebuild.
