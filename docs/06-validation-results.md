# Validation results — are the tools valuable / usable?

> The roadmap ([05](05-tooling-surfaces-and-roadmap.md)) lists capabilities. This
> doc is the evidence: we ran the tools against real corpora (tep, toy) with
> human-authored oracles and report what they found, where they agree, and where
> they (and Spinel's inference) fall short. Run on gx10 (aarch64-Linux), Spinel
> fork `feat/typing`, 2026-06-01/02.

## Summary

- **`--emit-rbs` agrees with hand-written RBS on ~73% of reachable methods**, and
  its disagreements are *systematic and defensible* — not random error.
- **`doctor` finds real risks on unseen code** (a silent emit-0 in toy's training
  path; precise `untyped` degrade sites).
- Both tools independently fingerprint the **same** inference frontier:
  polymorphic / heterogeneous types (subclass slots, `poly` receivers, mixed
  arrays) degrade to `untyped`/`Integer`.
- The **CRuby-oracle limitation generalizes**: tep *and* toy use FFI and won't
  load under CRuby, so the differential legs (value-bisect, doctor `behavior`)
  are blocked for most real Spinel apps. The static legs carry the value there.

## Experiment ① — `--emit-rbs` vs tep's 47 authored `.rbs`

Method: compile `examples/hello.rb` (pulls the whole ~40-file framework) with
`--emit-rbs`; compare structured signatures against `tep/sig/**.rbs`, keyed on
(class, method, singleton) with type-spelling normalization. Tooling:
`tools/value-bisect`-adjacent ad-hoc comparator (kept out of tree).

| Metric | Value |
|---|---|
| Authored methods | 524 |
| Reachable + mapped from one entry | 391 (74%) |
| **Exact signature agreement (of mapped)** | **287 (73%)** |

The ~27% that differ, categorized:

| Bucket | Count | Reading |
|---|---|---|
| Setter returns `Integer` (0) vs authored value type | 28 | Spinel reports the *compiled* return; author documents Ruby semantics. Spinel is right about the binary. |
| Param inferred nilable (`Request?`) vs authored `Request` | 21 | Spinel is *more conservative* — arguably more accurate. |
| Return differs (e.g. handler `->String` vs authored `->Integer`) | 21 | Spinel right (handlers return the body string). |
| Heap param collapsed to `Integer` | 10 | Uncalled methods: no call-site info → default numeric type. Coverage artifact. |
| `untyped` widening / `Array[Message]`→`Array[Integer]` | ~24 | The real limit: Filter/Handler subclass slots + heterogeneous arrays. Spinel self-marks these `#spinel:widenedtountyped(slowpath)`. |

Upshot: the inference export is structured, `rbs`-shaped, and trustworthy; the
`untyped` self-markers are exactly what the LSP surfaces. The one recurring real
limitation is polymorphic/heterogeneous containers.

## Experiment ② — `doctor` on toy (302-file numerical ML)

Static legs ran clean on a never-seen numerical codebase and surfaced:

- A **silent emit-0**: `TransformerLM#embed_backward` calls `.length`/`[]` on a
  `poly` `token_ids` → emits 0 → `t_seq = 0` → embedding gradients silently not
  accumulated. The dangerous "compiled != correct" mode in a *training* path.
  Filed: OriPekelman/toy#32.
- **12 `untyped` degrades**, all on the heterogeneous/`poly` first-args of the
  backward/decode methods — the same fingerprint as ①.

The `behavior`/`bisect` legs were **not applicable**: toy uses `ffi_lib` and
errors under CRuby (`undefined method 'ffi_lib'`), so there's no oracle. This is
the same wall as tep — see "limitation" below.

## Cross-cutting findings

1. **Valuable.** `--emit-rbs` matches hand specs on the clear majority with
   explainable misses; `doctor` finds real emit-0 + degrade sites on unseen code.
2. **One inference frontier, named twice.** Polymorphic/heterogeneous types are
   where inference (and thus the tooling's precision) gives way — and the tooling
   pinpoints exactly where. That's the highest-value place to push Spinel.
3. **The differential harness needs a single-sided mode.** The CRuby-oracle
   requirement (spinel-dev#1) blocks value-bisect and doctor's `behavior` leg for
   *any FFI-using app* — i.e. most real Spinel apps (tep, toy both). The static
   legs (compile-probe, degrade scan, `--emit-rbs`) are what deliver value there,
   so they should be the default and the differential legs opt-in when a
   CRuby-runnable entry exists.
4. **A blind spot remains (spinel-dev#3):** null-receiver crashes on statically
   non-nullable types are invisible to all four tools — see the matz/spinel#1259
   localization, which needed ASAN.

## Open issues spawned

- spinel-dev#1 — differential harness can't run CRuby-refusing/ FFI apps (now
  shown to generalize beyond tep).
- spinel-dev#2 — native backtrace name/file cosmetics.
- spinel-dev#3 — null-receiver crash blind spot.
- OriPekelman/toy#32 — guard poly-degradation in numerical paths (doctor CI gate).
- OriPekelman/tep#186 — the #1259 fix (uninitialized `@openai_events`).
