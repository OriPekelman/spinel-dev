# spinel doctor

One command that tells you everything risky about compiling a Ruby program with
Spinel — the cheap-to-expensive battery in one report.

```sh
./doctor.sh [--json] [--no-bisect] path/to/program.rb [-- program-args...]
```

It runs three checks, escalating in cost and in what they catch:

| Check | How | Catches |
|---|---|---|
| **compile** | `spinel -c`, scrape `cannot resolve call … (emitting 0)` | a call Spinel can't lower — it silently emits `0`/`nil` |
| **inference** | `spinel --emit-rbs`, find `# spinel: widened` | a method whose param/return fell to the boxed `untyped` slow path |
| **behavior** | the value-bisection harness vs CRuby (`../value-bisect`) | a **silent miscompile** — the binary computes a wrong value with no warning |

Only the behavior check catches silent miscompiles (they compile clean and exit
0), so it's the one that matters most — and it points at the variable + line.
Use `--no-bisect` to skip it (faster; static checks only).

## Output

```
spinel doctor: app.rb
  compile    ✓ no unresolved calls
  inference  ⚠ 1 method(s) widened to untyped (slow path / inference gap):
               - def show: (untyped) -> nil
  behavior   ✗ MISCOMPILE — diverges from CRuby (run bisect.sh for the site)
  verdict    miscompiles
```

`--json` emits one object (`{file, verdict, compile, inference, behavior}`) with
the nested bisect finding under `behavior` — for CI, agents, or a pre-commit
gate. `verdict` is `clean` | `degrades` | `miscompiles`.

## Requirements

- A built Spinel at `$SPINEL_DIR` (default `~/sites/spinel`) — needs `-c`,
  `--emit-rbs`, and (for the behavior check) the `--debug` path the harness uses.
- `SPINEL_INT_OVERFLOW` is passed through to the harness (pick `raise|wrap|promote`).

This is surface **A2** from `docs/05-tooling-surfaces-and-roadmap.md`.
