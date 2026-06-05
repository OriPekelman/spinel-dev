# Tooling for Spinel contributors & coding agents

> Prerequisites: [00-architecture-constraints.md](00-architecture-constraints.md),
> [01-debuggability.md](01-debuggability.md). This doc is the *operator's manual*
> for the tooling those notes proposed, now built.

This is written for two audiences who turn out to want the same things:

- **Contributors to `matz/spinel`** — people changing the compiler, who need to
  find where a change made the compiler wrong.
- **Coding agents** (Claude Code et al.) developing Spinel or Spinel apps — which
  is how Spinel and its ecosystem are actually built. Agents need *mechanical,
  parseable* signals they can act on without a human in the loop.

The unifying idea: **make the compiler's own knowledge observable**, and turn
"it's wrong somewhere" into "it's wrong *here*."

## Where this lives

The compiler changes staged on a fork — `OriPekelman/spinel`, branch
`feat/typing` (contains everything) — and have now **all landed upstream**, one
PR at a time: `--emit-rbs` (matz/spinel#1276), `--debug` (#1292), `--emit-types`
(#1298), native `Exception#backtrace` (#1300), and FloatArray ops (#1301) are
**merged**. The standalone tools live in this repo, `spinel-dev/tools/`. Why
fork-first then upstream incrementally: every change is opt-in and
`--debug`/env-gated, so non-debug output is byte-for-byte unchanged and the suite
stays green — but the surface area (a new parser field, a runtime backtrace, two
analyzer emit modes, a wrapper flag set) was worth exercising on real apps
(`tep`, `toy`) and settling per-PR in review rather than landing all at once.

## The tools, and the rationale for each

| Tool | What it surfaces | Why it's uniquely cheap in Spinel |
|---|---|---|
| `spinel --debug` (#line + native backtrace) | step the **Ruby** source in lldb/gdb; real `Exception#backtrace` | clean name-preserving C (`sp_<m>`, `lv_<local>`) + Prism locations the parser already had |
| **value-bisect** harness + **triage** | *where* a compiled binary first diverges from CRuby (var/line) or crashes | CRuby is a ready-made oracle (the `verified` rung formalizes this) |
| `spinel --emit-rbs` | inferred signatures as RBS; `untyped` marks the degraded slow path | whole-program inference already computes them |
| `spinel --emit-types` + ruby-lsp addon | inferred type on hover; degrade warnings | per-node type cache already serialized to the IR |
| **`spinel doctor`** (+ `doctor-gate`) | one report: ignored requires, emit-0s, widened slots, inference↔codegen **disagreements**, **codegen** build failures, behavior diff — and a CI gate over it | composes the legs above; the disagree/codegen legs need no new compiler work |
| **`spinel-reduce`** (+ `spinel-flatten`) | the **minimal trigger** for any doctor finding (ddmin); `flatten` inlines a gem's require graph first | doctor's `--json` *is* the oracle — no bespoke reducer per bug class |
| **`tools/perf/`** (`spinel-perf`, `spinel-flamegraph`, `speedup-estimate`, `rbs-disagree`) | "would it be faster / why slow": hot lines + GC-vs-user split, Ruby-demangled flamegraphs, a static port estimate, inferencer-disagreement coordinates | the same inference + `#line` substrate, pointed at speed |

The first four — plus doctor's behavior leg — attack the failure mode
`spinelgems`' ARCHITECTURE.md calls the dangerous one — the **silent miscompile**:
"it compiled" ≠ "it works", no warning. A native debugger doesn't help with those
(they aren't crashes); making the compiler's analysis and the CRuby differential
*visible* does. doctor's `disagree` and `codegen` legs extend that to the
*static* silent-miscompile fingerprint and to C-build failures that the analysis
legs alone read as "clean"; `spinel-reduce` shrinks any of them to a minimal
repro. (Tool detail: each tool's own README; the perf write-up is
[08-perf-analysis](08-perf-analysis.md).)

## Proof of value (runs you can reproduce)

### 1. Localize a real silent miscompile

`spinelgems` documents silent miscompiles caught only by a differential run. The
harness doesn't just catch them — it *points at the variable and line*. A
faithful reproduction is integer overflow under `--int-overflow=wrap` (Spinel
keeps a 64-bit `mrb_int`; CRuby promotes to Bignum):

```sh
cd spinel-dev/tools/value-bisect
SPINEL_INT_OVERFLOW=wrap ./bisect.sh examples/overflow.rb
```
```
[FIRST DIVERGENCE]  (earliest in execution order)
  file: overflow.rb   variable: x   line: 12
  CRuby : i:9223372036854775808      Spinel : i:-9223372036854775808
```
The 63rd left-shift overflows; the harness pins the exact iteration. For a
program split across files it reports the **root cause in the callee first**
(`compute.rb:7`), then the corrupted return in the caller — ranked by execution
order, not line number.

### 2. Confirm a documented footgun is now *fixed* (regression oracle)

`spinelgems` documents the **Int-0-as-nil** footgun: a stored `0` read back and
nil-checked takes the wrong branch (`h[k].nil? ? -1 : v` → `-1`). Run the harness
on a faithful repro against *current* Spinel:

```sh
./bisect.sh /tmp/int0nil.rb     # h = {"a"=>0}; v=h["a"]; v.nil? ? -1 : v
```
```
[OK] all 4 common scalar variables agree across their full change-histories.
```
Spinel now computes it correctly — the harness is a **regression oracle**: it
tells you a previously-documented miscompile no longer reproduces. (Finding this
also surfaced and fixed a harness false-positive — epilogue stops past EOF;
see the commit log.)

### 3. See a degrade the compiler is hiding

Where Spinel *can't* compile a call it prints `cannot resolve call to 'X'
(emitting 0)` and degrades. The typing tools make that visible *before* you run:

```sh
spinel app.rb --emit-rbs        # a poly-widened method -> `def f: (untyped) -> untyped # spinel: widened to untyped (slow path)`
spinel app.rb --emit-types      # JSON: per-position types + a diagnostic at each degraded def
```
Hover the same in an editor with the ruby-lsp addon (`tools/ruby-lsp-spinel`):
`**Spinel** infers untyped — ⚠️ boxed poly slow path`.

### 4. Crash & backtrace triage

```sh
./triage.sh --failing            # after `make test`: localize every FAIL/ERR
```
A bounded crash reports `CRASH  rec.rb:2  EXC_BAD_ACCESS`; an exception now
carries a real backtrace under `--debug`:
```
caught: divided by 0
app.rb:in `Calc#divide'
app.rb:in `<main>'
```

## The agentic dev loop

The point of mechanical output is that an agent can close the loop unattended:

1. **A test fails** (or a `verified` smoke diverges). Run `triage.sh --failing`
   → a one-line `VERDICT|diverge|file|var|line|cruby|spinel` (or `crash`/`abort`).
   The agent now has a *location*, not just "output differs".
2. **Localize → minimize → fix.** The (var, line) bounds where to look in the
   ~48k-line codegen / ~33k-line analyzer. The agent edits, rebuilds the affected
   stage, re-runs the harness on that one repro (seconds), and watches the
   VERDICT flip to `ok`.
3. **Guard against regressions.** Keep the repro; the harness *is* the assertion
   ("CRuby == Spinel"), stronger than a fixed expected-output string.
4. **Audit silent degrades** with `--emit-rbs` over the app: every `untyped` is a
   slow path or an inference gap to review — surfaced statically, no run needed.

This is the runtime complement to the static `rubocop_spinel` cops: the cops flag
*syntax* Spinel degrades; `--emit-rbs`/`--emit-types` flag where *inference*
degraded; the harness catches what neither can see — a value that's just wrong.

## Command reference

```sh
# Debugging (compiler changes on the fork; build once with `make`)
spinel app.rb --debug -o app && lldb -o 'b app.rb:N' -o run -o 'p lv_x' app
spinel app.rb -g                 # debug info + #line, keep your -O level

# Inference, made visible
spinel app.rb --emit-rbs         # -> app.rbs (rbs validate-clean)
spinel app.rb --emit-types       # -> app.types.json (positions + diagnostics)

# Differential value bisection (this repo)
tools/value-bisect/bisect.sh app.rb [-- args]      # exit 1 = divergence
tools/value-bisect/triage.sh --failing             # triage the test suite
SPINEL_INT_OVERFLOW=wrap tools/value-bisect/bisect.sh app.rb   # pick the mode

# One-shot risk report + CI gate (this repo)
tools/doctor/doctor.sh [--json] [--no-cruby] app.rb   # require/compile/inference/disagree/codegen/behavior
ruby tools/doctor/doctor-gate.rb --github             # CI: fail on a new degrade/disagreement/codegen error

# Minimal repro from a degrade (this repo)
ruby tools/reduce/spinel-flatten.rb smoke.rb -o flat.rb            # inline a gem's require graph
ruby tools/reduce/spinel-reduce.rb --target sp_box_int flat.rb     # ddmin to the minimal trigger

# Performance (this repo)
ruby tools/perf/speedup-estimate.rb app.rb            # static "would it be faster?"
ruby tools/perf/spinel-flamegraph.rb --gmon ./bin gmon.out -o flame.svg   # Ruby-demangled flamegraph
```

## Why propose this upstream

- **Zero cost when off.** Every feature is `--debug`/env-gated; the default
  pipeline, output, and the self-hosting bootstrap fixpoint are unchanged.
- **Small, mechanical surfaces.** A dedicated `node_line`/`node_col`/`node_file`
  parser field; a header-only native backtrace (no per-method codegen, no lib
  rebuild); two analyzer emit modes reusing existing tables; a wrapper flag set.
- **It targets Spinel's stated worst failure mode.** The project already built
  the `verified` differential because silent miscompiles are the danger; this
  makes that differential *point at the bug*, and the inference *visible*.

See [04-tooling-for-developers.md](04-tooling-for-developers.md) for the
gem-author / app-developer view, and
[05-tooling-surfaces-and-roadmap.md](05-tooling-surfaces-and-roadmap.md) for what
still needs building to make this land in real workflows.
