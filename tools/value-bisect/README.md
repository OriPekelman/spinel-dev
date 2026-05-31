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

Both sides emit, for every scalar local, the ordered history of values it takes
(recorded only when the value changes). The comparator aligns those histories
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
./bisect.sh path/to/program.rb [-- program args...]
```

Exit status: **0** = all common scalars agree, **1** = a divergence was found.

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

## Scope / limitations (v1)

- **Scalar locals only** — `mrb_int` / `mrb_float` / `mrb_bool`. Strings,
  arrays, hashes and user objects are runtime structs behind a pointer; the
  Spinel side lists them under `skipped_nonscalar` and they aren't compared yet.
  Formatting them through the runtime's `sp_*_to_s` helpers is the natural
  follow-up.
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
