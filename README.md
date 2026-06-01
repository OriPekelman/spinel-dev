# spinel-dev

Design notes and tooling research for [Spinel](https://github.com/matz/spinel),
the whole-program Ruby → C AOT compiler. This repo is **analysis and
proposals**, not a fork of the compiler. It exists to think through developer
experience questions that sit *around* Spinel — debugging, editor tooling, and
the boundary between Spinel-compiled code and interpreted CRuby — before any of
it lands as code in `matz/spinel` or the satellite projects.

Sibling projects this repo references:

- **[matz/spinel](https://github.com/matz/spinel)** — the AOT compiler itself
  (`spinel_parse` → `spinel_analyze` → `spinel_codegen` → C → native binary).
  Self-hosting; whole-program type inference; native C value model (no `VALUE`,
  no VM, no `eval`).
- **[spinelgems](https://github.com/OriPekelman/spinelgems)** (`bundler-spinel`)
  — dependency gating + the vendor flow that links C extensions *into* a Spinel
  binary, plus the `verified` differential (CRuby-vs-Spinel) harness.
- **[tep](https://github.com/OriPekelman/tep)** — Sinatra-flavoured web
  framework compiled through Spinel; the largest real-world Spinel app and a
  torture test for codegen.
- **toy** — pure-Ruby ML framework compiled by Spinel (Tep's downstream
  consumer). Not checked out alongside this repo at time of writing.

## Contents

| Doc | What it covers |
|---|---|
| [docs/00-architecture-constraints.md](docs/00-architecture-constraints.md) | The handful of Spinel design facts that govern every answer below. Read first. |
| [docs/01-debuggability.md](docs/01-debuggability.md) | Can byebug/pry work? An "auto LSP"? What Ruby tooling works today, what's cheap to build, what's structurally impossible. |
| [docs/02-compile-gems-reverse-cext.md](docs/02-compile-gems-reverse-cext.md) | Could Spinel compile Ruby *into a CRuby C-extension* — "compile gems" while keeping interpreted Ruby as the workhorse? Feasibility, the one hard seam, and the v1 target. |
| [docs/03-tooling-for-contributors-and-agents.md](docs/03-tooling-for-contributors-and-agents.md) | Operator's manual for the tooling built from doc 01 (debug/#line, value-bisect + triage, RBS/types export, LSP, native backtrace). Proof-of-value runs, the agentic dev loop, and the rationale for upstreaming. |
| [docs/04-tooling-for-developers.md](docs/04-tooling-for-developers.md) | The gem-author / app-developer how-to: check a binary matches CRuby, debug + backtrace, and read inferred types. |
| [docs/05-tooling-surfaces-and-roadmap.md](docs/05-tooling-surfaces-and-roadmap.md) | Gap analysis — what surfaces (CI, terminal, IDE/DAP, type-checker, packaging) are still needed to make the capabilities land, with a suggested order. |

The tooling itself lives in [`tools/`](tools/): `tools/value-bisect/`
(differential value-bisection harness + test-suite triage) and
`tools/ruby-lsp-spinel/` (the Spinel-aware ruby-lsp addon). The compiler-side
changes (`--debug`, `--emit-rbs`, `--emit-types`, native backtrace) live on the
`OriPekelman/spinel` fork, branch `feat/typing`.

## The one-paragraph summary

Spinel's design — closed-world, no VM, no `VALUE`, native-typed locals, no
call-stack frames, no `eval` — rules out runtime debuggers (byebug/pry) and a
live REPL into the binary, but makes two things cheap that are usually hard:
(1) **native-debugger stepping through Ruby source** via `#line` directives the
codegen can already emit (the analyzer carries Prism node locations, and locals
are already named `lv_<name>`), and (2) an **inference-export / Spinel-aware LSP
addon** that surfaces the compiler's per-node type analysis in the editor —
directly attacking the *silent miscompile* failure mode `spinelgems` documents.
The "compile gems into C-extensions" idea is the inverse of the whole
ecosystem's thesis (which drops CRuby at runtime), but it's tractable for
leaf, RBS-annotated, monomorphic kernels using RBS signatures as the boundary
marshalling contract and a value-in/value-out model that sidesteps cross-GC
integration.
