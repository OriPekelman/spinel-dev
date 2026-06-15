# Regression corpus: the f7ae245 family (spinel-dev#11–#14)

Four poly-widening / array-element-typing miscompiles, found while bringing
toy/tep onto Spinel, fixed in the **legacy Ruby compiler** on fork branches
that were never upstreamed:

| # | branch / tip | bug |
|---|---|---|
| [#11](https://github.com/OriPekelman/spinel-dev/issues/11) | `08a189c` | uncalled instance-method forwarder's `int` param mismatches a concrete callee C param at the dead-but-emitted call |
| [#12](https://github.com/OriPekelman/spinel-dev/issues/12) | `96c6c48` | same, but the callee is a **constructor** (`Klass.new(param)`) |
| [#13](https://github.com/OriPekelman/spinel-dev/issues/13) | `a699cf9` | a `poly_array` reaching a concrete `:int_array`/`:float_array` FFI boundary pointer-puns (toy eval `ggml_abort`) |
| [#14](https://github.com/OriPekelman/spinel-dev/issues/14) | `ddee073` | an array literal whose element is a forward-referenced constructor (`[FiberSlot.new(..)]`) degrades to `poly_array` at static init (toy serve boot crash) |

## Why these live here now

The matz/spinel **Ruby→C rewrite** moved the compiler from `spinel_analyze.rb`/
`spinel_codegen.rb` (now `legacy/`, oracle-only) to the hand-written C compiler
in `src/*.c`. The fork patches all touch the now-frozen `legacy/` tree, so they
**cannot upstream** — they are terminal.

But the C compiler fixes all four *independently* (verified on `b60fbd7`,
2026-06-15):

- **#11/#12** — whole-program parse + reachability-based dead-method
  elimination drops the uncalled forwarder before emission; no dead call site,
  no mismatch.
- **#13** — element-handoff FFI bridges (`sp_PolyArray_ffi_int_data` /
  `_float_data`) replace the pointer-pun. This is matz/spinel **#1389** =
  `b60fbd7`, the current master HEAD.
- **#14** — object arrays are natively `poly_array` (there is no `ptr_array`
  type), and `sp_PolyArray_delete_at` + runtime element dispatch make the
  seed-then-`delete_at` idiom work. matz/spinel **#1369** (the root issue) was
  closed the same day with the same finding.

So we keep the **repros, not the patches** — as a behavior guard against silent
regression in the C compiler. Each `.rb` failed on the pre-fix legacy compiler
with the symptom in its header comment; each passes on the C compiler today.

## Run

```sh
SPINEL_DIR=/srv/data/scratch/sp-master ./run.sh   # against a master C build
SPINEL_BIN=/path/to/spinel ./run.sh                # or point straight at a binary
./run.sh                                            # default: $HOME/sites/spinel/spinel
```

Exit 0 = all guarded fixes still hold.
