# spinel-reduce

Delta-debug a degrading Spinel program down to its **minimal trigger**
([spinel-dev#9](https://github.com/OriPekelman/spinel-dev/issues/9) proposal 5).

A size-/complexity-triggered degrade — an emit-0, an inference↔codegen
disagreement, a widened slot — is brutal to localize by hand (you bisect dims,
requires, ivar count, FFI-call count). This automates it: **ddmin** over the
source, with `spinel doctor --json` as the oracle. Keep removing code as long as
the *target finding still reproduces*; what survives **is** the cause.

```sh
SPINEL_DIR=~/sites/spinel ruby spinel-reduce.rb [--target SUBSTR] \
    [--no-cruby] [--keep-bisect] [-o min.rb] <degrading.rb>
```

- **target** — a substring of the finding to preserve. Default (most actionable
  first): a **codegen build error** (the failing C symbol, e.g. `sp_box_int` —
  [spinel-dev#10](https://github.com/OriPekelman/spinel-dev/issues/10)), else the
  inference↔codegen disagreement, else an ignored require, else an unresolved
  call, else a widened method. Override with `--target` (e.g. `--target sp_box_int`,
  `--target "incompatible type"`).
- **`--no-cruby`** — FFI/AOT-only app (single-sided doctor behavior leg), so it
  works where there's no CRuby oracle.
- **`--keep-bisect`** — also require the behavior verdict to reproduce (slow; for
  targeting a confirmed runtime miscompile rather than a static finding).

## How it works

1. **Structural pass** — remove whole top-level `def`/`class`/`module` blocks
   atomically (line-ddmin can't: removing one line of a `class … end` breaks
   syntax). Drops unrelated methods/classes in one shot.
2. **Line ddmin** — classic delta debugging on the remainder, with a fast
   `ruby -c` syntax gate before each (slow) `spinel` compile, and result
   memoization. Converges to a 1-minimal program.
3. **Structural pass again** — sweep up anything newly isolated.

## Example

A 45-line program (unrelated helpers, requires, a padding class, top-level calls)
around one method whose return widens to `untyped` reduces in **17 doctor calls
(~1.5s)** to exactly the trigger:

```
$ ruby spinel-reduce.rb -o min.rb noisy.rb
  target finding: "def get: (Integer) -> untyped"
  block-removed (cols 4-6) -> ...
  → wrote min.rb  (45 → 6 lines, 17 doctor calls)
```
```ruby
def get(flag)
  if flag > 0
    return {a: 1, b: 2, c: 3}
  end
  "hello"
end
```

The surviving lines are the minimal reproducer — paste them into a bug report, or
keep them as a regression fixture.

## `spinel-flatten` — point it at a *gem*, not a flat file

`spinel-reduce` needs one self-contained file. `spinel-flatten` inlines a
`require_relative` graph into one, so the gem → minimal-repro pipeline is
automatic ([spinel-dev#10](https://github.com/OriPekelman/spinel-dev/issues/10)
part 3):

```sh
ruby spinel-flatten.rb smoke.rb -o flat.rb        # inline the require graph
SPINEL_DIR=~/sites/spinel ruby spinel-reduce.rb --target sp_box_int flat.rb
```

It resolves `require_relative` **depth-first, in place** (a file's definitions
land before its use, preserving Ruby load order), dedupes repeated requires, drops
unresolvable ones with a marker (exactly as Spinel silently does — and `doctor`'s
`require` check flags), and leaves non-relative `require` (stdlib) lines untouched.

End to end: a 3-file gem smoke (`require_relative "lib/thing"` …) that boxes a
`Class` into a typed hash flattens to 33 lines, then reduces to a **13-line repro
in 26 doctor calls (~7s)** carrying just the `@table[:cls] = String` trigger.

## Limits (spike)

- **Code reduction, not parameter search.** It isolates *which* code is necessary
  (array-count vs ivar-count vs FFI-call-count), not the numeric threshold of a
  size-triggered degrade (e.g. "fails when the dim crosses ~512"). Shrinking a
  literal `627 → N` is a complementary axis a future pass could add.
- The oracle cost is one `spinel doctor` per candidate; budget seconds-per-call ×
  tens-to-hundreds of calls. Memoization + the `ruby -c` gate keep it bounded.

Needs a built `spinel` at `SPINEL_DIR`; uses `../doctor/doctor.sh` as the oracle.
