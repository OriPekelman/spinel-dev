# Debuggability of Spinel programs

> Prerequisite: [00-architecture-constraints.md](00-architecture-constraints.md).
> The conclusions here are consequences of those facts.

Debugging a Spinel program splits cleanly into two activities that want
*completely different* tools:

1. **Debugging the Ruby semantics** — "is my logic right?" Do this under CRuby.
2. **Debugging the binary** — "what is the compiled program actually doing?" Do
   this with a native debugger.

Conflating them is what makes "can I use byebug?" feel like a hard question. It
isn't, once you split it.

## byebug / pry: structurally impossible against the binary

byebug and pry are CRuby-VM artifacts:

- **byebug** is a C extension that hooks `TracePoint` / the VM's line-event
  machinery. Spinel has no VM and no `TracePoint`.
- **`binding.pry`** needs a live `Binding` (a mutable local-variable table) plus
  `eval` to run arbitrary expressions in that frame. Spinel has no `Binding` and
  no `eval` (constraint 3), and locals are native C variables that may be in
  registers or optimized away entirely.
- You cannot even load them: no `dlopen`, no C-ext loading (constraint 6).

A live REPL into a Spinel binary contradicts the AOT/closed-world model and is
**out of scope permanently** — not a missing feature, a category error. Don't
chase it.

## The cheap, correct answer: debug the same `.rb` under CRuby

The compiled subset is a subset of *real* Ruby. For everything except `ffi_func`
calls, the program runs identically under `ruby`, where byebug / pry /
`debug.gem` / ruby-lsp work at full fidelity. The only shim needed is defining
the `ffi_func` module methods in plain Ruby (which `tep` already does for its
batteries).

This is not a workaround — it's already the ecosystem's posture:

- `spinelgems` ships a **`verified`** rung: a *differential* run that executes a
  behaviour smoke under **both** CRuby and a Spinel-compiled harness and
  compares. That's CRuby-as-oracle, formalized.
- `tep` exists partly to "exercise Spinel against real Ruby; reduce bugs to
  minimal repros." Same idea: CRuby is where you understand the program; Spinel
  is where you ship it.

So the highest-value debugging story requires **zero new code** and is the
default recommendation.

## What works *today*, for free (source-level tooling)

A Spinel program is Ruby source parsed by **Prism** — the same parser ruby-lsp
uses. So all static, source-level tooling already works:

- **ruby-lsp** — go-to-definition, completion, hover, formatting, symbols.
  (`spinelgems` already has a `.ruby-lsp` dir; it's in use.)
- **RBS / Steep / Sorbet** — type checking. Spinel even *reads* RBS to seed
  inference, so the signatures you write for the type checker double as compiler
  hints.
- **`rubocop_spinel`** (gurgeous) — author-time cops that flag
  Spinel-unsupported Ruby (`class << self`, `Thread.new`, …) as you type. This
  is the static-risk signal `spinelgems`' probe also wants to consume.

The "auto LSP" you asked about partly already exists — it's just generic
ruby-lsp. The *interesting* part is making it Spinel-aware (below).

## What's cheap to build (binary-side + Spinel-aware), ranked by leverage

### 1. `#line` directives → step through Ruby source in gdb/lldb  ★ do this first

The single biggest win and genuinely small. The analyzer already carries Prism
node locations (constraint 5); emit `#line N "app.rb"` before each statement and
compile with `-g`. The C toolchain then produces DWARF that maps to **Ruby
source lines**. Combined with the existing `sp_<name>` / `lv_<name>` naming
(constraint 4), `gdb`/`lldb` immediately give you:

- breakpoints by Ruby line (`break app.rb:42`),
- `print lv_c` to inspect a Ruby local,
- native backtraces of compiled frames,
- watchpoints, stepping, reverse-debugging (rr), Time-Travel.

Scope: a `--debug` / `-g` driver mode (`-g -O0` + `#line` emission). Estimated a
few hundred lines in `spinel_codegen.rb` plus the `spinel` wrapper. **This is
the recommended first concrete deliverable.**

Caveat: at `-O2` the C compiler reorders/inlines and DWARF gets lossy, so
`--debug` should drop to `-O0` (and disable Spinel's own `static inline`
promotion) for faithful stepping.

### 2. Opt-in shadow call stack → restore `backtrace` / `caller`

Under `--debug`, push/pop `{file, line, method}` onto a thread-local array at
call entry/exit, and wire `Exception#backtrace` / `caller` to read it instead of
returning the empty `sp_StrArray` they return today (constraint 2). Gate it
behind the debug build because it adds per-call overhead. Medium effort;
restores the most-missed Ruby debugging affordance and makes exception output
actually useful.

### 3. Export inference results as RBS

The analyzer computes per-node inferred types and already reads RBS (constraint
8). Run it backwards: emit `sig/*.rbs` for the whole program. Benefits:

- feeds Steep / ruby-lsp / Sorbet with ground-truth signatures,
- doubles as a **miscompile diagnostic** — you can *see* where a param widened
  to `poly` (the slow path) or where a type came out wrong,
- closes the loop with constraint 8's existing RBS-in path.

Modest effort (the data is already serialized to IR; this is a new emitter).

### 4. Spinel-aware LSP addon — the "auto LSP" worth wanting

Not generated from nothing; the hard part (whole-program inference, serialized
to the IR's per-node type cache) is **done**. A thin ruby-lsp addon that reads
that cache can surface, on hover / as diagnostics:

- "Spinel infers `int_array` here",
- "this widened to `poly` — slow path; here's why",
- "this class can't be value-typed because <reason>" (loses the stack-alloc
  win),
- **"this call degrades to a no-op / can't be resolved"** — the scariest case.

That last one matters most. `spinelgems`' architecture doc names the central
danger explicitly: **silent miscompiles** — `eval` → "emitting 0", local-var-name
collapse, Int-0-as-nil — where "it compiled" ≠ "it works" and no warning fires.
A static linter (`rubocop_spinel`) catches *some* of this at author time, but
only the compiler's own inference knows when a *specific call site* degraded.
Surfacing that in the editor is a uniquely-Spinel tool and mostly plumbing over
existing data.

This is the most interesting thing to build after `#line`.

## What can't work (don't attempt)

- Live REPL / `binding.pry` into the binary (needs VM + `eval` + live retyping).
- Full `TracePoint` / `set_trace_func` emulation (needs the VM event model).
- Generic reflective inspection of arbitrary live objects (no uniform object
  header — constraint 1).

Lean on the CRuby dual-run for all of these.

## Recommended sequencing

1. `#line` + `--debug` mode (native debugger steps through Ruby). ← start here
2. Spinel-aware ruby-lsp addon surfacing inferred types + degrade warnings.
3. RBS export from inference (feeds #2 and external type checkers).
4. Opt-in shadow call stack for `backtrace`/`caller`.

(1) and (4) are compiler changes (PRs against `matz/spinel`); (2) and (3) can
live as standalone tools — (3) arguably belongs in `spinelgems`' orbit since it
already speaks RBS and ledgers.

## Honest note

`spinelgems` is organized around the premise that the dangerous failure mode is
the *silent* one. That's the strongest argument for prioritizing the
inference-export / Spinel-aware-LSP work (items 3–4 above) over a fancier
runtime debugger: the bugs that hurt aren't crashes you can catch in gdb, they're
correct-looking binaries that quietly do the wrong thing. Tooling that makes the
compiler's analysis *visible* attacks that directly; a runtime debugger doesn't.
