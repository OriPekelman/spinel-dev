# Perf analysis — "would Spinel make you faster?" / "why is it slow?"

> Proposal / discussion. The correctness tools answer *"does the compiled binary
> match CRuby?"* This is the performance counterpart: *should you compile this at
> all*, and *where is the compiled code paying for dynamism*. It reuses substrate
> we already built — no new compiler research.

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

### `spinel perf <program.rb> [-- args]` (dynamic)
Compile `-g`, run under `perf record` (Linux) / `samply` (cross-platform),
symbolize hot frames back to Ruby via the `#line` map, and **annotate each hot
line with its inferred type / degrade status**. Output: a flat profile keyed by
`.rb:line`, each tagged `[fast: Integer]` or `[SLOW: untyped poly]`, so "what's
slow" and "why" land together. (`Kernel#caller`, already built but unwired, gives
the Ruby-level call tree to go with it — roadmap E3.)

## Validating the predictor

Run a real benchmark corpus (e.g. [yjit-bench](https://github.com/Shopify/yjit-bench)
or the [Ruby Benchmark Suite](https://github.com/acangiano/ruby-benchmark-suite))
under both CRuby and Spinel, and correlate the measured Spinel/CRuby ratio with
the static degrade score. If "high degrade ⇒ slow" holds across the corpus, the
cheap static estimate is trustworthy as the "should I port?" gate. (If there's a
specific "Roundhouse" suite intended here, point it at that corpus — the harness
is corpus-agnostic.)

## Why this fits

It's the same thesis as the correctness tools: **expose what the compiler already
knows.** Inference tells you where dynamism survives into the binary; that's both
a *miscompile* risk surface and a *performance* risk surface. One scan, two
answers. #282 is the motivating case — the tool would have called that
interpreter "likely slower" statically, before the 30× surprise.
