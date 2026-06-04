# spinel doctor

One command that tells you everything risky about compiling a Ruby program with
Spinel — the cheap-to-expensive battery in one report.

```sh
./doctor.sh [--json] [--no-bisect] path/to/program.rb [-- program-args...]
```

It runs four checks, escalating in cost and in what they catch:

| Check | How | Catches |
|---|---|---|
| **compile** | `spinel -c`, scrape `cannot resolve call … (emitting 0)` | a call Spinel can't lower — it silently emits `0`/`nil` |
| **inference** | `spinel --emit-rbs`, find `# spinel: widened` | a method whose param/return fell to the boxed `untyped` slow path |
| **disagree** | cross-reference the two legs above | **inference↔codegen disagreement** — codegen emits-0 a call to a method *inference resolved* on a user class. The static silent-miscompile fingerprint ([spinel-dev#9](https://github.com/OriPekelman/spinel-dev/issues/9)) |
| **behavior** | the value-bisection harness vs CRuby (`../value-bisect`) | a **silent miscompile** — the binary computes a wrong value with no warning |

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
behavior}`) with the nested bisect finding under `behavior` — for CI, agents, or a
pre-commit gate. `verdict` is `clean` | `degrades` | `miscompile-risk` |
`miscompiles` (in ascending severity; `miscompile-risk` = a static disagreement
was found, `miscompiles` = behavior-confirmed). `doctor-gate` treats a disagreement
as an allowlistable-but-distinct finding, so a *new* one fails CI loudly.

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
