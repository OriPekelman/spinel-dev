# spinel-dev

Developer-experience tooling for [Spinel](https://github.com/matz/spinel), the
whole-program Ruby → C AOT compiler — plus the design notes (RFC / discussion)
that motivated it.

> **Status.** This repo began as analysis — *can Ruby tooling work at all against
> a closed-world, no-VM, no-`eval` compiler?* That question is now answered by
> **working tools**, below. The design docs remain as the rationale and the
> open-discussion surface; treat them as RFCs. The compiler-side changes the
> tools depend on live on the [`OriPekelman/spinel`](https://github.com/OriPekelman/spinel)
> fork, branch `feat/typing` — all opt-in / `--debug`-gated, non-debug output
> byte-for-byte unchanged.

## The tools

Each is runnable today. The standalone tools live in [`tools/`](tools/); the
compiler flags live on the fork.

### `spinel doctor` — one-shot health check
[`tools/doctor/`](tools/doctor/) · `doctor.sh [--json] [--no-bisect] <program.rb>`

Compile-probe + inference-degrade scan + behavior check in one command. Tells
you, for a given program: does it compile, which calls degrade to the silent
slow path (e.g. *unresolved call → emits 0*), which methods widened to
`untyped`, and — when the program runs under CRuby — whether its output matches.
Human-readable or `--json`.

### value-bisect — differential value localization
[`tools/value-bisect/`](tools/value-bisect/) · `bisect.sh [--json] <program.rb>`

Runs a program under CRuby (the oracle) and as a Spinel `--debug` binary,
traces the change-history of every scalar local on both sides, and reports the
first `(file, line, variable)` whose value diverges — pinpointing a **silent
miscompile**, the failure mode `spinelgems` calls the dangerous one. Multi-file
(`require_relative` chains traced too). `triage.sh --failing` localizes every
test-suite failure the same way. Consumed by `spinelgems verify` to upgrade a
"the outputs differ" verdict into a line to look at.

### ruby-lsp-spinel — inferred types in the editor
[`tools/ruby-lsp-spinel/`](tools/ruby-lsp-spinel/)

A ruby-lsp addon that surfaces Spinel's per-node type inference on hover, and
flags where a type degraded to the boxed poly slow path — directly attacking the
silent-miscompile problem at authoring time.

### Compiler flags (fork `feat/typing`)

- **`spinel --debug`** — `#line` directives for native-debugger (lldb/gdb)
  stepping through Ruby source, non-inlined methods, and native
  `Exception#backtrace` / `Kernel#caller` (macOS and Linux).
- **`spinel --emit-rbs`** — whole-program inference exported as RBS signatures.
- **`spinel --emit-types`** — the same inference as position-keyed JSON (what the
  LSP consumes).

## Design docs (RFC / discussion)

| Doc | What it covers |
|---|---|
| [00-architecture-constraints](docs/00-architecture-constraints.md) | The Spinel design facts that govern every answer below. Read first. |
| [01-debuggability](docs/01-debuggability.md) | Can byebug/pry work? An "auto LSP"? What works today, what's cheap, what's structurally impossible. |
| [02-compile-gems-reverse-cext](docs/02-compile-gems-reverse-cext.md) | Could Spinel compile Ruby *into a CRuby C-extension* — keep interpreted Ruby as the workhorse? Feasibility + the v1 target. |
| [03-tooling-for-contributors-and-agents](docs/03-tooling-for-contributors-and-agents.md) | Operator's manual for the tools above: proof-of-value runs, the agentic dev loop, the upstreaming rationale. |
| [04-tooling-for-developers](docs/04-tooling-for-developers.md) | Gem-author / app-developer how-to: check a binary matches CRuby, debug + backtrace, read inferred types. |
| [05-tooling-surfaces-and-roadmap](docs/05-tooling-surfaces-and-roadmap.md) | Gap analysis — which surfaces (CI, terminal, IDE/DAP, type-checker, packaging) are still needed, in suggested order. |

## Sibling projects

- **[matz/spinel](https://github.com/matz/spinel)** — the AOT compiler
  (`spinel_parse` → `spinel_analyze` → `spinel_codegen` → C → native). Self-hosting;
  whole-program inference; native C value model (no `VALUE`, no VM, no `eval`).
- **[spinelgems](https://github.com/OriPekelman/spinelgems)** (`bundler-spinel`) —
  dependency gating + the vendor flow that links C extensions *into* a Spinel
  binary, plus the `verified` differential harness (which calls value-bisect).
- **[tep](https://github.com/OriPekelman/tep)** — Sinatra-flavoured web framework
  compiled through Spinel; the largest real-world Spinel app and a codegen
  torture test.
- **toy** — pure-Ruby ML framework compiled by Spinel (Tep's downstream consumer).

## What Spinel needs to make this work (high-level)

Spinel's design — closed-world, no VM, no `VALUE`, native-typed locals, no
`eval` — rules out runtime debuggers and a live REPL, but makes two normally-hard
things cheap, given a few opt-in compiler hooks. At a high level, the tools above
depend on Spinel providing:

1. **A source-mapped debug build.** Emit `#line` directives back to the Ruby
   source and keep methods non-inlined under `--debug`, so a native debugger
   steps through Ruby and frames are real. *(Caveat: `#line` perturbs DWARF
   variable locations for functions with heap locals; the value-bisect harness
   sidesteps this by tracing a `#line`-free build and mapping C lines back.)*

2. **Inference export.** The analyzer already computes a whole-program type for
   every node; expose it as RBS and as position-keyed JSON so editors, type
   checkers, and the degrade-scanner can read what the compiler concluded —
   including where a type fell back to the boxed slow path.

3. **Native backtraces.** Snapshot the C stack at `raise` and format
   `sp_<method>` frames back to Ruby names. On Linux this additionally needs
   user methods at *external* linkage plus `-rdynamic` so the dynamic symbol
   table can resolve them (debug builds only).

The throughline: every capability is **opt-in and observability-only** — it
exposes what the compiler already knows or adds a debug-gated build mode, and
never changes the semantics or the byte-for-byte output of a release build.
