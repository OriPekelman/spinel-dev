# Perf tools — spike

Prototype for the two questions in [docs/08](../../docs/08-perf-analysis.md):
*"would Spinel make this much faster?"* (static) and *"why is my Spinel app
slow?"* (dynamic). This branch is a **spike** — proving the static signal is real
before investing; the dynamic half is sketched, not built.

## `speedup-estimate.rb` (static — prototyped)

Runs `--emit-rbs` and scores how much dynamism survives into the binary: a high
`untyped` ratio (the boxed poly slow path) predicts slow; concrete, numeric types
predict fast. No measurement — a heuristic proxy.

```sh
SPINEL_DIR=~/sites/spinel ruby speedup-estimate.rb fib.rb
#   verdict   likely MUCH faster — concrete, numeric-dominant
```

### First results (the signal is real, the limits are clear)

| program | untyped ratio | numeric share | verdict |
|---|---|---|---|
| `fib(30)` (numeric) | 0% | 100% | **likely MUCH faster** ✓ |
| tep `hello.rb` (framework) | 2.2% | 38% | likely faster |
| string/hash script (no `def`s) | — | — | marginal (no signal) |

Two honest limitations the spike exposed:

1. **It scores *compilation quality*, not *workload*.** tep types cleanly so it
   reads "faster," but it's I/O/web-bound — the CPU win is real but not the whole
   story. The static estimate answers "will the *compiled code* be tight," which
   is necessary-but-not-sufficient for "will my app be faster."
2. **Method-less scripts have no signal** — it only scans `def` signatures.
   Covering top-level / hot non-method code needs the per-node `--emit-types`
   JSON (#1298) instead of `--emit-rbs`.

## `validate-estimate.rb` — does the estimate track real speedups? (yes, ρ≈0.62)

Compiles + wall-times Spinel vs CRuby over Spinel's own 57-benchmark corpus
(compilable by construction), **subtracts process startup** (Spinel binaries
launch instantly; CRuby pays ~26 ms — on a sub-100 ms benchmark *that* is the
whole "speedup"), and rank-correlates the measured compute speedup with the
static score.

```
bench         cpu cruby  cpu spin  x faster  score  untyped  estimate
ackermann       0.312s    0.009s     33.8     1.00    0.0%   MUCH faster
fib             0.370s    0.018s     20.6     1.00    0.0%   MUCH faster
nqueens         0.141s    0.006s     24.9     1.00    0.0%   MUCH faster
gcbench         2.072s    0.300s      6.9     0.82    0.0%   MUCH faster
json_parse      0.170s    0.031s      5.4     0.10    0.0%   faster
csv_process     0.377s    0.144s      2.6     0.20    0.0%   faster
...                                       Spearman ρ = 0.62 (n=10)
```

Numeric/concrete code (score ~1.0) gets the biggest wins (20–34×); string /
parse / pointer code (score 0.1–0.2) the smallest (2.6–5.4×). **The static
estimate meaningfully orders the corpus by real speedup.**

Two honest caveats it surfaced:
- **Every Spinel benchmark is 0 % untyped** — they're cleanly typed, so here the
  *numeric-share* half of the score does the work; the *untyped/poly* predictor
  (the #282 case) is flagged statically (`micro_lisp` → 50 % untyped → "SLOWER")
  but its micro-workload is startup-dominated, so it isn't runtime-validated.
  Confirming the slow end needs a heavier dispatch-bound corpus *with* degrades.
- Anything under ~100 ms of compute is startup-dominated and excluded.

## `spinel-perf.rb` — the "why slow" profiler (working, per-line)

Compiles `-g -pg -O2` (the `#line` build, so the line table points at the `.rb`;
gprof since `perf` is locked down at `perf_event_paranoid=4` here), runs it a few
times and sums the profiles, then turns gprof's `-l` *line-level* `sp_<method>`
profile back into Ruby — de-mangled to a method, with the **source text** and the
`--emit-rbs` degrade overlay. `--json` for tooling.

```
$ SPINEL_DIR=~/sites/spinel ruby spinel-perf.rb bm_ao_render.rb
  hot methods (self-time, stable):
   16.0%   Vec#pool_recycle
   12.0%   Plane#intersect
   12.0%   Sphere#intersect
    8.0%   Scene#ambient_occlusion
  hot lines (sample-limited — gprof 10ms; heavier workload = finer):
    4.0%   Scene#ambient_occlusion  bm_ao_render.rb:242  x = Math.cos(phi) * Math.sqrt(1.0 - r)
```

### What "usability for perf data" needed (and the real limit)

The presentation is the easy, high-value part: **per-line + source text**, a
**stable per-method rollup** as the headline, the **`⚠` slow-path overlay**, JSON,
and multi-run summing. The hard limit is *data fidelity*: gprof samples at 10 ms,
so on sub-2 s workloads the exact hot *line* jitters run-to-run (the *methods* are
stable — hence leading with the rollup). Sharpening it needs a heavier workload,
or a higher-resolution sampler (`perf`, blocked here). So: usable format, gprof-
limited data.

The overlay is wired (`⚠` on a hot `untyped` method); Spinel's own benchmarks are
cleanly typed, so it correctly tags nothing on them.

## Next, if this is worth pursuing

- A heavier, *poly-heavy* corpus (a real interpreter / parser, or scaled-up
  `micro_lisp`) to validate the untyped→slow end and exercise the `⚠` overlay.
- A higher-resolution sampler where `perf` is permitted (or a userspace sampler),
  to make per-line stable — gprof is the portable fallback, not the ceiling.
- Switch the `⚠` overlay to `--emit-types` (#1298) so it's **per-line**, not
  per-method; and use it in `speedup-estimate` for method-less / top-level code.

Discussion: [spinel-dev#5](https://github.com/OriPekelman/spinel-dev/issues/5).
