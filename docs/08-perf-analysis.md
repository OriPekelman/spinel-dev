# Perf analysis — "would Spinel make you faster?" / "why is it slow?"

> Proposal → **now partly measured.** The correctness tools answer *"does the
> compiled binary match CRuby?"* This is the performance counterpart: *should you
> compile this at all*, and *where is the compiled code paying for dynamism*. It
> reuses substrate we already built — no new compiler research. The tools below
> are spiked in [`tools/perf/`](../tools/perf/) (branch `spike/perf-tools`); the
> **Measured results** section records what they found on a real Rails app.

## Measured results (roundhouse Rails blog) — see [`tools/perf/README.md`](../tools/perf/README.md)

The spike ran the full battery against [roundhouse](https://rubys.github.io/roundhouse/)'s
Rails blog (one app AOT-compiled to spinel, ~1.4–1.9× over CRuby). The headline
**overturned the starting hypothesis**, which is the useful part:

- **The ceiling is allocation, not boxing.** A live `-pg` profile (30k req/endpoint
  through the fiber server) split self-time as **~55% GC/alloc, ~25% other runtime,
  ~7–10% user code** — *flat across endpoints*, matching the flat ~20ms p99. The
  "hot ∧ poly" share (user self-time on the boxed slow path) is **≈0%**: the
  residual poly is real but *cold*. So on Rails-shaped glue, AOT already won the
  dispatch battle; what's left is object-allocation pressure (`#new` + view
  helpers), which AOT doesn't remove. This decomposition answers
  [spinel-dev#7](https://github.com/OriPekelman/spinel-dev/issues/7)'s tier
  question: reaching the crystal tier here is an allocation-strategy problem
  (escape analysis / scalar replacement / pooling), not a type-inference one.
- **Granularity matters and cuts both ways.** Signature (`--emit-rbs`) vs position
  (`--emit-types`) untyped: 22.8% of methods vs 3.19% of positions. The signature
  scan *under*-counts on a clean-boundary/boxed-body method (`churn`) and
  *over*-counts at app scale — both are why an *unweighted* scan can't predict
  speedup, and why the profile-weighted score is load-bearing.
- **Residual boxing = inferencer disagreement, and some of it is by design.**
  `rbs-disagree.rb` found 48 positions where roundhouse says concrete and Spinel
  widened (e.g. `ArticleRow#body: String` → `untyped`). The culprit is a
  `Hash[String, untyped]` read (`row["body"]`) — and per upstream
  [`docs/HASH-NULLABLE.md`](https://github.com/matz/spinel/blob/master/docs/HASH-NULLABLE.md)
  a `str_poly_hash` read **is** a `poly` slot by design, while
  [`docs/RBS-EXTRACT.md`](https://github.com/matz/spinel/blob/master/docs/RBS-EXTRACT.md)
  notes seeds are advisory and the analyzer **widens on observed contradiction**.
  So that widen is the analyzer working as documented (roundhouse-optimistic vs
  spinel-conservative), not a clear bug — the open question is the `body`/`title`
  asymmetry (why one widens and the structurally-identical other survives).

## The premise (matz/spinel#282)

Spinel is **not** uniformly faster than CRuby. It compiles *tight, monomorphic,
numerically-typed* code to clean C and wins big; it loses on *polymorphic,
dispatch-heavy, dynamic* code — exactly the shape of #282's tree-walking
interpreter (every var reference walks a string-keyed hash + `strcmp`; every node
visit recurses through boxed poly dispatch with GC rooting). CRuby's YARV gets
interned-symbol envs, inline caches, and stack frames "for free"; an AOT tree
walker doesn't.

So the useful questions aren't "is AOT faster" (sometimes) but:

- **CRuby project / gem author:** *"Would compiling with Spinel make me much
  faster, marginally faster, or slower?"* — before investing in the port.
- **Spinel project:** *"It's slower than I hoped. Which Ruby is slow, and why?"*

## The substrate already exists

The two halves of an answer are things the correctness tooling already produces:

1. **A static slowness predictor — the degrade scan.** `--emit-rbs` /
   `--emit-types` mark every slot where inference fell to the boxed `untyped` /
   poly slow path. That **is** the "where Spinel can't generate fast C" map. A
   high untyped/poly ratio (especially on hot, dispatch-shaped methods) predicts
   the #282 outcome; a low ratio over numeric code predicts a big win — *without
   running anything*. `spinel doctor` already counts these.

2. **A dynamic hot-spot mapper — the `#line` map.** A `--debug` / `-g` build
   carries `#line` directives (now upstream, #1292). That lets an off-the-shelf
   native profiler (`perf`, `gprof`, `samply`) attribute hot **C** samples back to
   **Ruby** source lines — the same map value-bisect uses for crash localization.

Overlay the two and you get the payoff sentence: *"62% of runtime is in
`parser.rb:120–155`, which the degrade scan shows on the poly slow path
(`node` is `untyped`) — that's your cost, and that's why."*

## Proposed tools

### `spinel speedup-estimate <program|gem>` (static, cheap)
Runs the degrade scan + a few structural heuristics (numeric vs string/hash vs
dispatch-shaped; share of calls that resolve monomorphically; container churn)
and emits a verdict + evidence:

```
likely MUCH faster   — 96% of methods monomorphic-typed, numeric-dominant, no poly dispatch
marginal             — mixed; hot path types cleanly but I/O-bound
likely SLOWER         — 40% untyped/poly, string-keyed-hash dispatch dominates (cf. #282)
```

This is the "should I even try" gate for a CRuby gem author — and it's mostly a
re-presentation of `--emit-types` we already have.

### `spinel perf <program.rb> [-- args]` (dynamic) — spiked as `tools/perf/spinel-perf.rb`
Compile `-g`, profile, symbolize hot frames back to Ruby via the `#line` map, and
**annotate each hot line with its inferred type / degrade status** — a flat profile
keyed by `.rb:line`, each tagged on the boxed slow path or not, plus a **GC-vs-user
self-time split** (the thing that surfaced the allocation ceiling above), so "what's
slow" and "why" land together. Note: `perf` is locked down on the gx10 box
(`perf_event_paranoid=4`), so the spike uses **gprof** (`-pg`); `perf`/`samply`
would sharpen the per-line resolution where permitted.

## Validating the predictor — done (two corpora)

- **Spinel's own 57-benchmark suite** (CRuby vs Spinel, startup subtracted):
  Spearman ρ = 0.62 (n=10) between the static degrade score and the measured
  compute speedup — the cheap scan meaningfully orders programs. Caveat: every
  Spinel benchmark is 0% untyped, so the *numeric-share* half carries it there.
- **roundhouse Rails blog** (the missing dispatch/alloc-heavy corpus): see
  Measured results above — the static degrade score correctly reads low (the poly
  is cold), and the real ceiling turned out to be GC/alloc, which the dynamic
  GC-split profile surfaces. The two corpora together cover the numeric and the
  glue ends; a poly-*hot* corpus (a real interpreter) is the remaining gap.

## Why this fits

It's the same thesis as the correctness tools: **expose what the compiler already
knows.** Inference tells you where dynamism survives into the binary; that's both
a *miscompile* risk surface and a *performance* risk surface. One scan, two
answers. #282 is the motivating case — the tool would have called that
interpreter "likely slower" statically, before the 30× surprise.
