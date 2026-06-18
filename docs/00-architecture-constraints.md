# Architecture constraints that govern everything

Every conclusion in the other docs follows from a small set of Spinel design
facts. They are collected here once so the rest doesn't have to re-litigate
them. All of these were confirmed against the `matz/spinel` checkout, not
assumed.

> **Note:** the compiler has since been rewritten Ruby→C (`src/*.c` →
> `bin/spinel`). The constraints below still hold, but internals references
> naming `spinel_analyze.rb` / `spinel_codegen.rb` now describe the **legacy**
> Ruby oracle, not the authoritative C compiler.

## 1. No VM, no runtime object model, no uniform `VALUE`

Spinel does whole-program type inference and lowers Ruby to **native C types**:
`mrb_int`, `double`, `sp_String*`, typed containers (`sp_IntArray*`,
`sp_StrIntHash*`, …), and value-type structs passed on the stack. Most values
are **unboxed** and carry **no per-object class tag**. There is no boxed
universal value the way CRuby has `VALUE`.

Consequence: there is no live object you can interrogate generically at
runtime. The README notes user objects inside a polymorphic value still render
as the placeholder `#<Object>` because "the runtime has no class-name table
yet." Anything that depends on a uniform object header (most reflective
debuggers) has nothing to hook.

## 2. No call-stack frame management

The C call stack *is* the Ruby call stack. `Exception#backtrace` returns an
empty `sp_StrArray` and `caller` is deferred — confirmed in codegen, with the
comment "spinel doesn't track per-exception frames (no call-stack management in
the AOT model)." Many short methods are emitted `static inline`, so they don't
even exist as distinct frames after the C compiler runs.

Consequence: backtraces, `caller`, and any frame-walking debugger feature are
absent unless explicitly reconstructed (see the shadow-stack proposal in
[01-debuggability.md](01-debuggability.md)).

## 3. Closed world: no `eval`, no `require`, no metaprogramming

The compiled subset has no `eval`, no runtime `require` (it inlines
`require_relative`), no `define_method`/`method_missing`-driven dispatch in the
compiled path. The program is fully known at compile time.

Consequence: a live REPL (`binding.pry`) is impossible — you cannot introduce
new code, and you cannot re-type a local at a breakpoint. Whole-program
inference *depends* on this closed world, which is also why a library boundary
(see doc 02) is the hard case.

## 4. Native C output is clean and name-preserving

This is the asset that makes native debugging viable. `def add(a, b); c = a + b;
c * 2; end` compiles to:

```c
static inline mrb_int sp_add(mrb_int lv_a, mrb_int lv_b) {
    mrb_int lv_c = 0;
    lv_c = sp_int_add(lv_a, lv_b);
    return sp_int_mul(lv_c, 2LL);
}
```

Methods → `sp_<name>`, locals → `lv_<name>`. A native debugger sees recognizable
symbols and recognizable local names.

## 5. `#line` directives and source mapping — SHIPPED

`grep -c '#line'` in codegen now returns nonzero: Spinel stamps `#line N
"app.rb"` before each statement **by default** (`--line-map`; opt out with
`--no-line-map`). C compile errors map back to Ruby source lines, and `--debug`
(`-g -O0`, non-inlined) gives faithful `gdb`/`lldb` stepping through Ruby.
The analyzer carries the Prism node line/column locations this rests on. This
was formerly the single highest-leverage debuggability gap; it is now **closed**.

## 6. FFI is outward-only; output is always a whole program with `main()`

`ffi_func`/`ffi_lib`/`ffi_cflags` let a Spinel program **call into C**. There is
no inward path: Spinel does not `dlopen`, cannot load a CRuby `.so` extension
(`spinelgems` marks such gems `rejected:c-extension`), and the driver always
emits a standalone executable with `main()` — no `-fPIC`, no shared-library
mode, no `Init_<name>` entry. The runtime is shipped as a static lib
(`lib/libspinel_rt.a`).

Consequence: the "compile a gem into a CRuby-loadable `.so`" idea (doc 02)
requires *new* build modes and a *new* boundary — none of the existing FFI/vendor
machinery does it, because it all points the other way.

## 7. Spinel has its own GC, disjoint from CRuby's

Mark-and-sweep with size-segregated free lists; value-type-only programs emit
**no GC at all**. There is no integration with CRuby's GC.

Consequence: any Spinel↔CRuby object exchange must either copy at the boundary
(value-in/value-out) or solve cross-GC rooting. The former is cheap and safe;
the latter is a research project. Doc 02 takes the former.

## 8. Inference already produces a per-node type cache, and reads/writes RBS

The analyzer (the legacy module was `spinel_analyze`) serializes a per-AST-node
inferred-type cache into the IR, and the toolchain already *consumes* RBS
(`spinel_rbs_extract`, `--rbs DIR`).

Consequence: exporting inferred types is no longer future plumbing — it **ships
today**. `--emit-rbs` writes inferred sigs to `.rbs`, and `--emit-types` writes
per-position inferred types plus degrade diagnostics as JSON; `--emit-symbol-map`
attributes C symbols back to Ruby. Surfacing those in an editor (doc 01) is the
remaining net-new work. And RBS is the natural boundary contract for doc 02.
