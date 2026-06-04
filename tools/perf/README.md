# Perf tools — spike

Prototype for the two questions in [docs/08](../../docs/08-perf-analysis.md):
*"would Spinel make this much faster?"* (static) and *"why is my Spinel app
slow?"* (dynamic). This branch is a **spike**.

## Measured on a real Rails app (roundhouse) — and the hypothesis was wrong

@rubys handed us a real corpus: [roundhouse](https://rubys.github.io/roundhouse/)
compiles one Rails blog to a stock-MRI `ruby` target and an AOT `spinel` target
from the same IR, and AOT buys **1.4–1.9×** over CRuby (far below the 20–34× of
tight numeric code). We ran the whole battery against it. Three findings, the
last one a surprise that overturned our own prediction:

**1. The two-granularity untyped gap is real but points the *opposite* way at
the app level (Q1).** `--emit-rbs` vs `--emit-types` over the whole app:

| granularity | untyped | what it means |
|---|--:|---|
| signature (`--emit-rbs`) | **22.8%** of 569 method/attr signatures | a method counts if *any* slot widens |
| position (`--emit-types`) | **3.19%** of 13,342 positions | the true density of boxed positions |

At the *method* (`churn`) scale the signature scan *under*-counts (clean boundary,
boxed body); at the *app* scale it *over*-counts (one widened return marks a whole
method whose body is concrete). Both are failures of *unweighted* scanning — which
is the whole argument for hot-weighting. Boxing concentrates in specific files
(`action_dispatch/flash.rb` 23.7%, `session.rb` 25.8%, the `*_params` models 21.7%).

**2. The dynamic profile refutes the "hot ∧ poly explains it" hypothesis — and
confirms the GC ceiling (Q2 vs Q3).** We built the blog `-pg`, drove 30k
requests/endpoint through the live fiber server (it shuts down cleanly on SIGTERM,
so gprof flushes), and split self-time:

| endpoint | GC/alloc | other runtime | user | hot ∧ poly (of user) |
|---|--:|--:|--:|--:|
| `/articles` (index HTML) | **55.6%** | 24.8% | 10.0% | **0%** |
| `/articles/1.json` | **56.1%** | 28.7% | 6.8% | **0%** |

The prediction was that hot∧poly would rise as speedup falls. It didn't — **hot∧poly
is ≈0**: the residual poly (finding 3) is *real but cold*. What dominates is
**GC/alloc at ~55%, flat across endpoints** — which is exactly @rubys's flat ~20ms
p99 ceiling (his Q3), now attributed. The top *user* methods are almost all `#new`
constructors and string-building view helpers, i.e. allocation sites. **So the
Rails speedup ceiling is allocation pressure, not dispatch boxing** — and AOT
can't remove the allocations. (This is why the new `gc_pct` split in `spinel-perf`
is load-bearing: without separating GC from user self-time, you'd never see that
the bottleneck isn't in the Ruby at all.)

**3. The residual boxing *is* an inferencer disagreement (Q5) — `rbs-disagree.rb`.**
roundhouse ships its own inferred RBS (`sig/**`); Spinel re-infers. Where roundhouse
says concrete and Spinel widens, the two disagree on a position one of them got
wrong. `rbs-disagree.rb` finds **48** such coordinates on the blog — e.g.
`ArticleRow#body: String` (roundhouse) vs `untyped` (Spinel), while `title`
(identical source shape) agrees. The tool localizes the culprit: `self.body =
row["body"]` where `row` is `Hash[String, untyped]`, so the untyped hash-read poisons
the `body` slot program-wide. A naive same-field minimal repro does *not* reproduce
it (confirmed: see `rbs-disagree.rb`'s header) — the widen is context-specific — so the tool hands you the
coordinate + suspects, not a guaranteed repro. Each ⚠ is a candidate bug on one
inferencer or the other.

```sh
SPINEL_DIR=~/sites/spinel ruby rbs-disagree.rb main.rb sig .   # entry, consumer-rbs-dir, src-root
```

## Granularity is everything (thanks @rubys, spinel-dev#5)

Sam Ruby's key correction: a *method-signature* scan (`--emit-rbs`) is blind to
boxing *inside* a method body — clean `(self) -> String` boundaries whose loops
build strings and dispatch dynamically. So it **structurally over-predicts** on
Rails-shaped code. The fix is two steps of granularity. On a method that builds a
heterogeneous array internally (`churn`, in the tests):

| scan | `churn` untyped | what it sees |
|---|---|---|
| `--emit-rbs` (signature) | **0 %** | `(Integer) -> Integer` — clean, misses it |
| `--emit-types` (position, #1298) | **10.6 %** | catches the 5 poly positions — but unweighted |
| **hot ∧ poly** (position × profile) | **100 %** | the poly is *where all the time goes* |

Each step reveals more, and **hot-weighting is the load-bearing one** — a cold
poly position doesn't matter; a hot one is the whole cost. Both tools now use
`--emit-types` positions (falling back to `--emit-rbs` if the engine predates
#1298).

## `speedup-estimate.rb` (static — no run)

Scores the **position-level** `untyped`/`poly` share (`--emit-types`): high →
slow, concrete/numeric → fast. The cheap "should I port this gem?" gate. It's
unweighted (can't know which positions are hot), so it still over-predicts for
code like `churn` — that's what `spinel-perf` corrects.

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
gprof since `perf` is locked down at `perf_event_paranoid=4` here), sums a few
runs' profiles, and turns gprof's `-l` *line-level* `sp_<method>` profile back
into Ruby — de-mangled, with the **source text** and a **per-line** `--emit-types`
poly overlay. The headline is **hot ∧ poly**: how much of user self-time sits on
the boxed slow path. `--json` for tooling.

```
$ SPINEL_DIR=~/sites/spinel ruby spinel-perf.rb churn.rb
  hot ∧ poly: 100% of user self-time is on the boxed slow path  (per-line via --emit-types)
   22.2%  ⚠ churn                  churn.rb:9  s = a[j].to_s
$ ... bm_ao_render.rb   (cleanly typed numeric)
  hot ∧ poly: 0% ...
   16.0%    Vec#pool_recycle
   12.0%    Plane#intersect
```

`churn` is the demonstration: `--emit-rbs` calls it clean (`(Integer)->Integer`),
so the old per-method overlay scored **0%** — but the time is entirely on
`a[j].to_s` where `a` is `poly_array`, which `--emit-types` flags and the hot
weighting puts at **100%**. Exactly the over-prediction @rubys called out.

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
