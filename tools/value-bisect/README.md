# value-bisect — differential value-bisection for Spinel

Find **where** a Spinel-compiled program silently diverges from CRuby, not just
**that** it does.

Spinel's most dangerous failure mode (per the `spinelgems` design notes) is the
*silent miscompile*: the program compiles and runs, but quietly computes the
wrong value — no crash, no warning. The `verified` differential rung tells you
CRuby and Spinel *disagree*; it doesn't tell you which value first went wrong.
This harness does, and its output is mechanical enough to drop straight into an
agentic dev loop (see `../../docs/01-debuggability.md`, and the `--debug` mode
it builds on).

## How it works

```
program.rb ──┬─► CRuby + TracePoint(:line) ─► per-variable value history ─┐
             │                                                            ├─► compare ─► first divergence
             └─► spinel --debug ─► lldb line-trace of lv_* locals ────────┘
```

Both sides emit, for every scalar or string local, the ordered history of
values it takes (recorded only when it changes). The comparator aligns them
**by value sequence** (not by line — the two runtimes attribute a change to
different lines) and reports the first local whose value diverges: file,
variable, value on each side, and the source line.

**Multi-file:** require_relative'd files are traced too. The set of compiled
files comes from the parser's `FILE` records (which back `--debug`'s multi-file
source map), and variables are keyed by `<file>::<var>` so same-named locals in
different files don't merge. Findings are ranked by the oracle's **execution
order**, so a root cause in a callee (e.g. `compute.rb:7`) is reported before
its downstream consequence in the caller (`main.rb:3`) — even though the caller
sits on a lower line number.

Alignment is robust to:
- the two runtimes firing a different number of line events for the same
  control flow (they routinely do);
- Spinel's zero-initialised locals producing a phantom leading `0` before a
  variable's first real assignment — handled by trying the alignment with and
  without the leading entry and keeping whichever agrees longest (so even a
  wrapped result that happens to equal `0` is reported as `0 vs <big>` rather
  than vanishing).

## Usage

```sh
./bisect.sh [--json] [--no-cruby] path/to/program.rb [-- program args...]
```

Exit status: **0** = all common scalars agree, **1** = a divergence was found.

### Single-sided mode (`--no-cruby`)

Some real programs can't run under CRuby at all — FFI apps (`ffi_lib` is undefined
in plain Ruby) and AOT-only frameworks (tep raises on `require`). With no oracle
there's nothing to diff, but the Spinel side is still worth tracing: `--no-cruby`
skips the CRuby leg and reports `crash` (localized to a `.rb` line) or `ran`
(clean, exit code) from the compiled binary alone. This is also **auto-detected**
— if the program raises immediately under CRuby (exit 70), bisect falls back to
single-sided on its own rather than emit a misleading `exit-differ`.

Caveat: a program that *calls into FFI* must still link its C objects. bisect now
scrapes the codegen's `SPINEL_LINK`/`SPINEL_CFLAGS` markers, so it links when
those resolve — but a marker left as an unsubstituted `@PLACEHOLDER@` (e.g. tep's
`@TEP_SPHTTP_O@`) won't build; run such apps with their placeholders substituted
(their own build, or a vendored copy).

Environment:
- `SPINEL_DIR` — Spinel checkout (default `~/sites/spinel`)
- `SPINEL_INT_OVERFLOW` — `raise` | `wrap` | `promote` (default `raise`)
- `CC` — C compiler (default `cc`)

Requires `make parse` to have been run in `$SPINEL_DIR`. The Spinel build uses
the Ruby interpreter path (`ruby spinel_codegen.rb`), so it always reflects the
current compiler source and does **not** need the native binaries rebuilt.

## Worked example

`examples/overflow.rb` left-shifts a value 70 times. Spinel's inference keeps it
a 64-bit `mrb_int` (unlike repeated doubling, which it auto-promotes to Bigint),
so under `--int-overflow=wrap` it silently overflows:

```sh
SPINEL_INT_OVERFLOW=wrap ./bisect.sh examples/overflow.rb
```
```
[FIRST DIVERGENCE]
  variable : x
  line     : 12
  change # : 63
  CRuby    : i:9223372036854775808
  Spinel   : i:-9223372036854775808
```

The 63rd shift sets bit 63 and the `mrb_int` wraps negative while CRuby promotes
to a Bignum — pinpointed to the variable and iteration. `examples/correct.rb` is
the negative control (stays in range → exit 0).

`examples/multifile/` puts the overflowing helper in a separate
`require_relative`'d file; the harness reports the root cause in
`compute.rb` first and the corrupted return value in `main.rb` second.

## Test-suite triage

`triage.sh` wires the harness into Spinel's test suite: instead of "test X
failed, output differs", it tells you *where* — variable + line for a
miscompile, file:line + signal for a crash.

```sh
cd ~/sites/spinel && make test          # writes build/test-results/*.ok
triage.sh --failing                     # triage every FAIL/ERR
# or target specific tests:
triage.sh test/foo.rb test/bar.rb
```

Each failing test gets one of:

| Verdict | Meaning |
|---|---|
| `MISCMP` | a scalar/string local diverges — `var @Lnn  CRuby=…  Spinel=…` |
| `CRASH`  | Spinel faulted — `file:line  EXC_BAD_ACCESS/SIGSEGV…` |
| `ABORT`  | Spinel raised/exited nonzero before CRuby's result |
| `OPAQUE` | output differs but no scalar/string divergence (container/output state, or an -O2-specific bug the -O0 trace doesn't reproduce) |
| `NOBUILD`| the harness couldn't compile the test |

Crash localization walks to the nearest Ruby-source stack frame, so a fault in
runtime C is reported at the `.rb` line that reached it. (Crashes that only
happen after very long execution — e.g. deep-recursion stack overflow — may hit
the trace's stop cap before faulting; bounded crashes are caught fast.)

## Scope / limitations

- **Heap-local programs now work** (the previous load-bearing caveat is fixed).
  Background: `#line` directives corrupt clang's DWARF variable-location info, so
  lldb reads a function's locals from the wrong stack slot whenever it has a
  GC-rooted (heap) local — every local, including scalars derived from an array,
  reads as its zero-init. Rather than trace the `#line` build, `bisect.sh`
  derives a C-line → Ruby-position map from the `#line` directives, blanks them
  out (preserving line count, so DWARF is clean), traces the resulting binary,
  and maps each stop back to Ruby. Locals then read correctly. (The shipped
  `spinel --debug` *stepping* feature still misreads locals in such functions —
  that's `p lv_x` over corrupt DWARF; documented separately.)
- **Rational / Complex** locals are tagged `rat:<n>/<d>` / `cpx:…` (Spinel has no
  such type — it silently yields an int like `0`), so e.g. `2 ** -1` (CRuby
  `1/2`, Spinel `0`) localizes instead of being skipped as a one-sided var.
- **Output-diff fallback.** When no scalar local diverges, the two runtimes'
  *stdout* is compared too — a divergent method return consumed straight by
  `puts foo(x)` has no local to trace, but the output still differs. Verdict
  `output-differ` (with the first differing line), so a real miscompile is never
  reported as a false `ok`. (Coarse — no variable; for the precise site the value
  must land in a local.)
- **Bigints** are compared (`sp_Bigint*` → `i:<decimal>` via one
  `sp_bigint_to_s` call) — e.g. a doubling loop that Spinel auto-promotes
  matches CRuby's Bignum. **Arrays** (`a:[…]`) and **typed hashes** (`h:{…}`,
  Str/Int/Sym/Poly-keyed) are compared too: int/string arrays are read straight
  from the runtime struct, while float arrays and hashes go through one inferior
  call to the runtime's own `sp_*_inspect` (its output matches CRuby's
  `Array#inspect`/`Hash#inspect`, so the two sides line up byte-for-byte). Hashes
  with a non-scalar key/value are skipped on the CRuby side (one-sided, not a
  false diverge). User objects are still not compared.
- Strings are compared up to the first NUL (embedded-NUL binary strings are a
  gap) and capped at 64 KiB.
- **Per-file, not per-method scoping.** Variables are keyed by `<file>::<var>`,
  so two methods *in the same file* sharing a local name still merge their
  histories. Keying by function would need the Spinel↔CRuby name mapping to
  agree (it doesn't for class methods: `sp_Foo_bar` vs `:bar`).
- `-O0` only (debug build).
- The reported line is where the changed value is first *observed* — typically
  the statement just after the write.

## Files

| File | Role |
|---|---|
| `bisect.sh` | orchestrator — runs both sides and the comparator |
| `cruby_trace.rb` | CRuby oracle: TracePoint → value history (JSON) |
| `spinel_lldb_trace.py` | lldb script: line-trace `lv_*` locals → value history (JSON) |
| `compare.py` | aligns the two histories, reports first divergence |
| `examples/` | `overflow.rb` (diverges under wrap), `correct.rb` (control) |
