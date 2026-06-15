# Helping downstream projects move with spinel master

> **Status: partly implemented.** Motivated by absorbing the matz/spinel **Ruby→C
> compiler rewrite** (the `f6d5eef..b60fbd7` wave, 763 commits, June 2026). This
> doc generalizes that experience into reusable tooling so toy / tep / spinelgems
> can track a fast-moving `matz/master` without each one re-deriving the same
> migration archaeology by hand. **Tools 1 (`spinel-migrate`) and 2
> (`spinel-probe`) are now built** ([`tools/migrate/`](../tools/migrate/),
> [`tools/probe/`](../tools/probe/)); tools 3–4 remain proposals.

## The problem, from a real case

matz/spinel rewrote the compiler from the self-hosted Ruby backend
(`spinel_analyze.rb` / `spinel_codegen.rb`) into hand-written C under `src/*.c`.
The Ruby tree moved to `legacy/` (oracle-only); the authoritative `spinel` is now
a C binary. For downstream consumers this single upstream event produced *four
distinct kinds of break*, and absorbing it took a full session of manual work:

1. **Layout moved.** `spinel_analyze.rb`/`spinel_parse` left the repo root for
   `legacy/`; `make all` now builds the C compiler. Anything hardcoding the old
   paths broke — our own `value-bisect/bisect.sh`, and toy's `SPINEL_DEPS`
   (toy#24's "Makefile adapt" chore).
2. **Error model changed.** The C compiler is *strict*: where the legacy compiler
   silently emit-0'd an unlowerable call (`cannot resolve … (emitting 0)`), the C
   compiler hard-errors (`spinel: unsupported …`). Tools keying on the old warning
   read a hard failure as **"✓ clean"** (the false-green we found in `doctor.sh`).
3. **Emit modes became exclusive.** `SPINEL_EMIT_SYMBOL_MAP` used to ride along a
   normal codegen run; on the C compiler it's an *emit-only* mode that writes an
   empty `.c`. Two perf tools silently broke on it.
4. **Parity gaps, surface-dependent.** The C compiler fixed our whole #11–#14 bug
   family — but isn't yet at toy-parity: serve/eval fail with *new* codegen gaps
   (`$stderr.puts` malformed C, `Array.new(n,<float>)` mistyped, …), and they only
   reproduce on the **full** compilation surface, not isolated probes (the
   recurring "f7ae245 signature").

None of this was knowable without building master and running the project's real
targets through it. That manual probe — *compile each target on the old pin and
the candidate, diff the outcomes, attribute each new failure to a source site* —
is the work worth tooling. spinel-dev's role is quietly shifting from "DX tooling"
to **the absorption layer between a fast-moving compiler and the apps on top of
it**; these tools make that role first-class.

## Proposed tools

### 1. `spinel-migrate` — the parity probe (highest leverage) · **built**

Given a project's build targets and two compilers (the current pin and a
candidate, e.g. master), compile every target with both and report a **go/no-go
diff**:

```
spinel-migrate --from $TOY_PIN --to /srv/data/scratch/sp-master \
               --targets lib/toy/run/serve.rb lib/toy/run/eval.rb --rbs sig
```

For each target × compiler it records: compiled? · binary size · first
`spinel:`/`cc` error attributed to a **Ruby** source site (via the `#line` map +
`--emit-symbol-map`, exactly as `doctor.sh` leg 2c already does). Output is the
table I built by hand for toy — `serve: ✗ logger.rb:52 …, eval: ✗ transformer.rb:74
…` — plus a verdict: *ready* / *blocked-on-N-compiler-bugs* / *project-side fix
needed*. This is `doctor`, batched over a project's targets and **differenced
across two compilers**; the novel part is the diff + attribution rollup, and it
directly answers the only question that matters at a big bump: *can we move yet,
and if not, what exactly is in the way?*

Reuses: doctor's compile/attribution legs, the symbol map, `#line`. New: target
discovery (read a project's build entrypoints), the two-compiler diff, the rollup.

### 2. `spinel-probe` — capability & layout manifest (the substrate) · **built**

A one-shot that interrogates a `$SPINEL_DIR` and prints a manifest:

```json
{ "driver": "c-binary", "layout": "legacy-split", "legacy_dir": ".../legacy",
  "runtime_lib": ".../lib", "flags": ["--emit-types","--emit-rbs","--emit-symbol-map","--debug"],
  "error_model": "strict", "symbol_map_mode": "emit-only" }
```

Every tool here currently re-discovers these facts — and the version-guard debt we
just deleted (pre-#1345/#1298 fallbacks, `LEGACY_DIR` detection, emit-0-vs-strict
branching) was the *scar tissue* of doing it ad hoc. A shared probe lets tools —
and **downstream Makefiles** (toy's `SPINEL_DEPS`) — adapt to layout/flag/error-
model shifts at one well-tested point instead of hardcoding paths. This is the
cheapest item and it pays for itself the next time the layout moves.

Reuses: the detection logic already written into `bisect.sh` (LEGACY_DIR) and
`doctor.sh` (strict-vs-emit-0). New: consolidate + emit as a manifest; have the
other tools consume it.

### 3. `spinel-gate-bisect` — first-bad compiler commit for a project gate

Wrap `git bisect run` over a spinel rev range with the project's own gate
(compile / boot / test) as the discriminator, skipping toolchain-broken revs
(exit 125). The siblings ran this **by hand** for the #13/#14 regressions
(d6756fa, the 59-skip wall). Distinct from `value-bisect`, which localizes a value
*within* one compile: this localizes *which upstream commit* first broke the app.

Reuses: the gate-running + skip discipline from the manual bisects. New: the
`git bisect run` wrapper + a project-gate adapter.

### 4. `spinel-reduce-project` — multi-file-aware reduction · **built**

The f7ae245 signature — *isolated probe compiles, full surface miscompiles* —
defeats single-file ddmin: two of the serve blockers (`backoff`, the multi-arg
`realize_for`) would not minimize in isolation and had to be filed un-reduced.
`spinel-reduce-project` ([`tools/reduce/spinel-reduce-project.rb`](../tools/reduce/spinel-reduce-project.rb))
reduces across the real `require_relative` graph, preserving the compilation
unit. Crucially the oracle is the project's **own build** (`spinel [--rbs DIR]
<entry> -o bin`), not `doctor -c` on a flattened file — so `--rbs`, FFI
link/cflags, and require resolution behave exactly as in the real build (a
flattened single file breaks FFI and mis-resolves requires; `doctor` doesn't
pass `--rbs`). Two ddmin passes: drop whole files from the graph (empty their
bodies), then drop top-level defs/classes from the survivors, keeping only what
still reproduces the target error. The minimal file set + surviving defs is a
filable repro.

Reuses: `spinel-reduce`'s ddmin + block logic, `spinel-flatten`'s require-graph
DFS. New: the real-build oracle, file-granularity reduction, in-place mutate
with restore-on-exit.

## Suggested order

1. **`spinel-probe`** — small, unblocks the others, retires the version-guard
   class of bug for good.
2. **`spinel-migrate`** — the headline; codifies the manual go/no-go probe. Built
   on the probe + doctor.
3. **`spinel-gate-bisect`** — when migrate says "blocked", find the first-bad.
4. **Multi-file reduction** — when the blocker is surface-dependent, get a repro.

## What this asks of the compiler

Nothing new — the substrate already exists (`#line`, `--emit-types/-rbs/
-symbol-map`, deterministic `spinel:` diagnostics). The one nicety that would
sharpen `spinel-migrate`'s attribution: a stable machine-readable form for the
codegen-refusal diagnostics (today `spinel: unsupported call: node N …` is
human-prose). A `--diagnostics=json` akin to `--emit-types`' diagnostics array
would let migrate attribute refusals as precisely as it attributes `cc` errors.

## Cross-references

- The rewrite-absorption work that motivated this: spinel-dev#14 (closed),
  #24/#25 (remaining C-compiler toy-parity gaps), matz/spinel#1369 (closed),
  the `regression/absorbed-by-c-rewrite/` corpus.
- Tool substrate: [03](03-tooling-for-contributors-and-agents.md) (doctor +
  bisect), [05](05-tooling-surfaces-and-roadmap.md) (roadmap; this extends
  surface A), [08](08-perf-analysis.md) (the `#line`/emit reuse pattern).
