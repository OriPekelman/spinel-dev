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

## `spinel-perf` (dynamic — sketch, not built)

The "why slow" half: compile `-g`, run under `perf record` / `samply`, symbolize
hot frames back to Ruby via the `#line` map (the same map value-bisect uses), and
**annotate each hot line with its inferred type / degrade status**, so a flat
profile reads `parser.rb:142  38%  [SLOW: untyped poly]`. `Kernel#caller`
(built, unwired — roadmap E3) would give the Ruby call tree.

## Next, if this is worth pursuing

- Validate the static predictor against a benchmark corpus (yjit-bench / Ruby
  Benchmark Suite): does high untyped-ratio actually track slow Spinel/CRuby
  ratios? If yes, the cheap estimate is a trustworthy "should I port?" gate.
- Switch `speedup-estimate` to `--emit-types` for node-level coverage (no-method
  scripts, hot top-level loops) + weight by a cheap call-count if available.
- Build the `perf` → `#line` → degrade-overlay profiler.

Discussion: [spinel-dev#5](https://github.com/OriPekelman/spinel-dev/issues/5).
