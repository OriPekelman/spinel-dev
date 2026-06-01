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
1. `spinel --debug` — `#line` stepping + native `Exception#backtrace` (backtrace
   is **macOS-only** so far — see Open #1).
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

## Open next steps (pick by value)

1. **Native `Exception#backtrace` on Linux** (currently empty). glibc's
   `backtrace_symbols` uses a different format *and* can't resolve `static`
   functions. Fix is contained but needs a gx10 fork rebuild: in
   `lib/sp_runtime.h`'s `sp_bt_symbol`, parse the Linux `module(sym+0xoff)`
   format; make user methods **non-`static`** in debug (`method_linkage_named` in
   `spinel_codegen.rb`) and link the debug build with `-rdynamic` so the symbols
   are resolvable. Then rebuild (`make codegen`) on gx10 and re-test
   `/tmp/bt.rb --debug`.
2. **spinelgems `verify` → self-localize.** When the differential smoke diverges,
   have `spinel-compat verify` call `bisect.sh --json` to upgrade `L2 cruby=…
   spinel=…` to a variable + line. (spinelgems is at `~/sites/spinelgems`.)
3. **Validate on `tep` / `toy`** — run the whole battery (`spinel doctor`,
   harness, `--emit-rbs`) on a real multi-file app. The realistic stress test;
   surfaces what breaks at scale (multi-file maps, the harness, the LSP).

## Build / rebuild notes

- The wrapper prefers the native `spinel_analyze` / `spinel_codegen` binaries;
  after editing those `.rb` files, `make codegen` rebuilds them (gx10 ≈ 3 min).
  `make parse` rebuilds the C parser only.
- The harness uses the Ruby path explicitly, so it reflects `.rb` edits without a
  rebuild.
