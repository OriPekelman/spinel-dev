# spinel doctor

One command that tells you everything risky about compiling a Ruby program with
Spinel — the cheap-to-expensive battery in one report.

```sh
./doctor.sh [--json] [--no-bisect] path/to/program.rb [-- program-args...]
```

It runs six checks, escalating in cost and in what they catch:

| Check | How | Catches |
|---|---|---|
| **require** | `spinel -c`, scrape `… the (call\|require) is ignored` | an **ignored `require`** — a wrong relative path or an unshipped stdlib that Spinel silently drops. If it defines a module the program calls, *every* call to that module then emits 0. The prime suspect for an emit-0 cascade ([spinel-dev#9](https://github.com/OriPekelman/spinel-dev/issues/9)) |
| **compile** | `spinel -c`, scrape `cannot resolve call … (emitting 0)` | a call Spinel can't lower — it silently emits `0`/`nil` |
| **inference** | `spinel --emit-rbs`, find `# spinel: widened` | a method whose param/return fell to the boxed `untyped` slow path |
| **disagree** | cross-reference the two legs above | **inference↔codegen disagreement** — codegen emits-0 a call to a method *inference resolved* on a user class. The static silent-miscompile fingerprint ([spinel-dev#9](https://github.com/OriPekelman/spinel-dev/issues/9)) |
| **codegen** | `cc -c` the emitted C (compile-only) | a **C build failure** — the analysis legs pass but the emitted C won't compile (a Class boxed as int, a reopened `Object` struct, an undeclared local). Classified `incompatible-type` / `unknown-type` / `redefinition` / `undeclared-identifier` / `arg-count-mismatch` with the offending symbol. The bulk of real harness finds ([spinel-dev#10](https://github.com/OriPekelman/spinel-dev/issues/10)) |
| **behavior** | the value-bisection harness vs CRuby (`../value-bisect`) | a **silent miscompile** — the binary computes a wrong value with no warning |

The **codegen** check closes the gap where the analysis legs read "clean" but
`spinel -o` fails `cc`: it compiles the C the probe already emitted (compile-only,
so no link/FFI-object noise) and classifies the first diagnostic. A program that
fails `cc` now reads `verdict: codegen-error`, never `clean` — and `spinel-reduce
--target <symbol>` can ddmin it to the minimal trigger.

The **require** check gets top billing because an ignored require is the cheapest
root cause of the scariest symptom: a real toy blocker was `require_relative
"../tinynn"` off by one directory → `TinyNN` never loaded → every `TinyNN.tnn_*`
call resolved "on int" and emitted 0 → zero weights → loss stuck at 0. doctor now
names the ignored require *and* correlates it to the emit-0 cascade below it,
instead of burying it among 40 look-alike `on int` lines.

The **disagree** check is the static counterpart to behavior: when `--emit-rbs`
resolves a method (e.g. `Engine#realize!`, or a `X.new` constructor) but the
codegen leg can't (`cannot resolve call to 'realize' on int (emitting 0)`), the
receiver's class was *lost at codegen* while inference knew it — the call silently
no-ops. This is the **malign** subset of `on int`: an emit-0 on a *user* method or
constructor is a lost-receiver bug; an emit-0 on an FFI/builtin call (e.g.
`tnn_upload` on int) is the expected `:ptr`-as-int lowering and is *not* flagged.
It needs no CRuby oracle, so it reaches FFI/AOT-only apps where the behavior leg
can't run. Use `--no-bisect` to skip the behavior leg (the three static checks
still run).

## Output

```
spinel doctor: app.rb
  compile    ✓ no unresolved calls
  inference  ⚠ 1 method(s) widened to untyped (slow path / inference gap):
               - def show: (untyped) -> nil
  behavior   ✗ MISCOMPILE — diverges from CRuby (run bisect.sh for the site)
  verdict    miscompiles
```

`--json` emits one object (`{file, verdict, compile, inference, disagreements,
codegen, behavior}`) with the nested bisect finding under `behavior` and a
`{error_class, symbol, message}` object under `codegen` — for CI, agents, or a
pre-commit gate. `verdict` is `clean` | `degrades` | `miscompile-risk` |
`miscompiles` | `codegen-error` (the last = the emitted C won't build, which
trumps the rest since there's no binary to run). `doctor-gate` treats a
disagreement as allowlistable-but-distinct (a *new* one fails CI loudly) and a
codegen error as a hard, never-allowlistable failure (a non-building program is
never acceptable).

## `doctor-gate.rb` — doctor as a CI gate

`doctor` reports; `doctor-gate` **decides** — it runs doctor over a set of
entrypoints and exits non-zero on a *new* degrade or any miscompile, so it drops
into CI as one step.

```sh
ruby doctor-gate.rb [--config FILE] [--allow PAT]... [--github] [--json] [FILE.rb ...]
```

The load-bearing idea is the **allowlist**. A degrade can be benign *today*
because the path is dead — e.g. [toy#32](https://github.com/OriPekelman/toy/issues/32):
`embed_backward` widens to `untyped`, but every gated training path runs through
the FFI/ggml engine, never the Ruby method. The behavioral (byte-exact) gates
can't protect a path they don't exercise. So acknowledge the known-dead degrades
in an allowlist; the gate then fires the moment a **new** one appears — i.e. when
a refactor re-activates a latent degrade while all the behavioral gates stay
green. That's the exact regression class the value-checks structurally can't see.

```yaml
# .spinel-doctor-gate.yml  (auto-discovered in the working dir)
spinel_dir: ~/sites/spinel          # optional; env SPINEL_DIR wins
defaults: { no_cruby: true }        # FFI/AOT-only app — single-sided behavior leg
entrypoints:
  - lib/toy/run/train.rb
  - { path: lib/toy/run/infer.rb, no_cruby: true }   # per-entry override
allow:                              # acknowledged dead-but-latent degrades
  - embed_backward                  # substring-matched against the degrade text
  - cross_entropy_grad
```

- **Exit codes:** `0` clean / all degrades allowlisted · `1` a new degrade or a
  miscompile · `2` setup error.
- A finding is *allowed* if any `allow:` pattern is a substring of its text
  (`def get: … untyped`, or a `cannot resolve call to 'x'` line).
- An allow entry that matches nothing is reported as **stale** (the degrade is
  gone — remove it). Stale entries warn but don't fail.
- A live **miscompile** (behavior diverges/crashes) is *never* allowlistable —
  it always fails.
- `--github` emits `::error::`/`::warning::` workflow annotations; `--json` emits
  `{pass, entrypoints[], new_degrades[], miscompiles[], stale_allow[]}`.

GitHub Actions step:

```yaml
- name: spinel doctor-gate
  run: ruby tools/doctor/doctor-gate.rb --github
  env:
    SPINEL_DIR: ${{ github.workspace }}/spinel
```

See `examples/toy.spinel-doctor-gate.yml` for the toy#32 configuration.

## Requirements

- A built Spinel at `$SPINEL_DIR` (default `~/sites/spinel`) — needs `-c`,
  `--emit-rbs`, and (for the behavior check) the `--debug` path the harness uses.
- `SPINEL_INT_OVERFLOW` is passed through to the harness (pick `raise|wrap|promote`).

This is surface **A2** from `docs/05-tooling-surfaces-and-roadmap.md`.
