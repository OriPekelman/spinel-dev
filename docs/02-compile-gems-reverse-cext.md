# Spinel as a "gem compiler": Ruby → CRuby C-extension

> Prerequisite: [00-architecture-constraints.md](00-architecture-constraints.md).

**The question.** Could we use Spinel to transform existing Ruby into a CRuby
C-extension (`.so` / `.bundle`) that interpreted Ruby `require`s — so we
"compile gems" (or hot methods) while keeping CRuby as the main workhorse?

**The short answer.** Yes, for a constrained-but-valuable class of code, and
the work concentrates almost entirely at *one seam* (the CRuby↔Spinel value
boundary). But be clear-eyed: this is the **inverse of the entire
spinel/tep/toy thesis**, so almost none of the existing machinery applies, and a
couple of pieces are genuinely new.

## First, why this is the inverse of everything else

The Spinel ecosystem's bet is: **compile the whole app, drop CRuby at
runtime.** `tep` is a single native binary with no Ruby runtime; `toy` is
pure-Ruby ML compiled the same way; `spinelgems` exists to get *dependencies*
into that whole-program compile.

Your question flips the polarity: **keep CRuby running, compile only the hot
gems/methods into loadable extensions.** That's the "rewrite the hot path in C /
Rust" play (`rb-sys`, `magnus`), except you write Ruby and Spinel emits the C.

Two ecosystem facts confirm nothing does this today:

- `spinelgems/docs/c-ext.md` is about the **opposite** plumbing — linking
  hand-written `.c` *into* a Spinel binary via `ffi_cflags`. Its own caveat:
  *"Vanilla CRuby c-ext gems are out... Spinel doesn't `dlopen`."*
- The driver always emits a whole program with `main()` — no `-fPIC`, no
  shared-lib mode, no `Init_<name>` (constraint 6).

So this is new ground, not a config flag.

## What blocks it today

1. **No shared-library / `Init_` output mode.** Spinel emits `main()` +
   standalone executable only (constraint 6).
2. **Disjoint object models.** Spinel values aren't `VALUE`s; there's no boxing
   and no class tag (constraint 1).
3. **Two independent GCs** (constraint 7).
4. **Whole-program inference assumes a closed world** (constraint 3). At a
   library boundary the *callers are unknown* — the one assumption Spinel leans
   on hardest is exactly the one a public API surface violates.

## What makes it tractable (and actually elegant)

### a. The boundary already has a contract: RBS

Spinel reads RBS to seed inference (constraint 8). Make the **exported,
public** methods' RBS signatures the marshalling contract:

```rbs
def add: (Integer, Integer) -> Integer
```

tells the generated `Init_` shim exactly how to convert (`NUM2LL` in, `LL2NUM`
out) and what `TypeError` guards to emit. Crucially, **only the exported surface
needs the contract** — internal/private methods, called only from within the
compiled unit, still get full whole-program inference. That separation lines up
perfectly with how a gem is actually shaped (small public API, larger private
guts) and neatly dodges blocker #4.

### b. You already own the type-conversion vocabulary

The FFI type table (`:int`→`int`, `:str`→`char*`, `:ptr`, byte buffers, struct
reads) is *precisely* the marshalling table needed at a CRuby boundary, just
pointed the other way:

| Boundary direction | Operation |
|---|---|
| `VALUE` → Spinel (entry) | `NUM2LL`, `StringValueCStr`→`sp_String`, `RARRAY`→`sp_IntArray`, type-check + `TypeError` |
| Spinel → `VALUE` (return) | `LL2NUM`, `rb_str_new`, build `RArray`, etc. |

And the runtime already ships as a static lib (`lib/libspinel_rt.a`), so an
extension links it the way a hand-written C-ext links its deps.

### c. Value-in / value-out sidesteps the GC problem entirely

This is the key design choice that turns blocker #3 from a research project into
a non-issue. If exported methods:

- take CRuby values, convert to Spinel-native **at entry**,
- run purely in Spinel-native types,
- convert results to **fresh** CRuby objects **at return**,
- and never share a mutable object graph across the boundary,

then **no cross-GC integration is needed.** Spinel allocations are scoped to the
call. For numeric/algorithmic kernels you can go further and use a **per-call
arena** (allocate on entry, free on return) and emit **no GC at all** — Spinel
already does exactly this for value-type-only programs.

## The realistic v1 target

**Leaf, monomorphic, RBS-annotated computational methods with no Ruby callbacks
or blocks crossing the boundary.** That is — not coincidentally — exactly the
code people hand-write C-extensions (or Rust + `magnus`) for today: hot numeric
kernels, parsers, encoders, tree/graph algorithms. The pitch:

> Annotate the hot method with RBS, `spinel --emit-ext`, `require` the resulting
> `.so`, keep the rest of the gem interpreted.

Same value proposition as `rb-sys`/`magnus`, but you write Ruby — and, uniquely,
the boundary marshaller is **derived from inferred/RBS types** rather than
hand-written. No other Ruby-native-ext toolchain does that derivation.

## Effort breakdown

| Piece | Effort | Notes |
|---|---|---|
| `-fPIC` + shared-lib build mode + emit `Init_<gem>` instead of `main()` | **Small** | Driver/codegen plumbing. |
| Generate `extconf.rb` / `mkmf` glue + link `libspinel_rt.a` | **Small** | RubyGems' native-ext path already supports this packaging. |
| RBS-driven boundary marshaller: scalars + String + homogeneous Array/Hash, with `TypeError` guards | **Medium** | Reuses the FFI conversion vocabulary, reversed. |
| Map Spinel `raise` → `rb_raise` | **Small–Medium** | So Ruby sees real exceptions. |
| **Partial compilation unit** driver mode: take a class/module, treat exported params as RBS-typed roots, run inference over that closed set, emit no `main` | **Medium** | The one genuinely *new* compiler piece. Everything else is driver/runtime. |
| Blocks / `yield` / callbacks into Ruby; exchanging live mutable objects | **Large — defer** | Forces re-entrancy and/or cross-GC rooting. Out of v1 scope. |

## Prior art to study

- **Natalie** — Ruby → C++ AOT, the closest cousin; look at how it shapes
  compilation units and the runtime boundary.
- **`rb-sys` / `magnus`** — the canonical modern Ruby C-ext boundary-shim
  pattern (Rust). Steal the ergonomics; note that *neither derives the boundary
  from types* — that's Spinel's potential differentiator.
- **`mkmf` / `extconf.rb`** — the packaging/loading mechanics a produced gem
  must satisfy.

## The honest caveat (inherited from spinelgems)

`spinelgems` is built around the premise that the dangerous failure mode is the
**silent miscompile**. A gem boundary makes that *worse*, because the consumer
can't see the inference and trusts a `require`d `.so` implicitly. So for this
path, two things are **not optional**:

1. **Boundary guards** — every exported method must type-check its `VALUE` args
   and raise `TypeError` rather than reinterpret bits, because the compiled body
   assumes monomorphic types.
2. **A `verified`-style differential** — run the method under CRuby *and* through
   the compiled extension on the same inputs and compare, exactly like
   `spinelgems`' `verified` rung. That's what converts "it linked" into "it's
   correct." It should be a required gate before a compiled ext ships.

## Where this would live

- The compiler changes (shared-lib mode, partial-unit inference, marshaller,
  `raise`→`rb_raise`) are PRs against **`matz/spinel`**.
- The packaging + differential-verification harness fits naturally in
  **`spinelgems`**' orbit — it already speaks RBS, runs differential smokes, and
  owns the gem-facing tooling. A `spinel-compat emit-ext` / `verify-ext` pair
  would be the consumer-side surface.
