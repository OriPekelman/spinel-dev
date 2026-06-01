# Tooling for Spinel gem authors & app developers

> You're writing Ruby that you compile with Spinel (an app like `tep`, or a gem
> you want to be Spinel-`verified`). This is the practical "how do I…" guide.

Spinel compiles a *subset* of Ruby to a native binary. The good news: that subset
is real Ruby, so most of your debugging happens under plain `ruby`. The tooling
here is for the gap — where the compiled binary behaves differently, where
inference quietly weakened a type, or where you need a backtrace from the binary.

## "Is my logic right?" → run it under CRuby

Your program runs under `ruby` (define your `ffi_func` shims in plain Ruby, as
`tep` does). There you have byebug, pry, `debug.gem`, ruby-lsp — everything, at
full fidelity. **Do logic debugging here.** The tools below are for the other
question: *does the compiled binary do the same thing?*

## "Does the compiled binary match CRuby?" → value-bisect

The dangerous bug in Spinel isn't a crash — it's a value that's quietly wrong
("it compiled" ≠ "it works"). One command tells you *where*:

```sh
cd spinel-dev/tools/value-bisect
./bisect.sh path/to/script.rb [-- your args]
```

It runs your program under CRuby (the oracle) and as a Spinel `--debug` binary,
and reports the first local whose value diverges — variable, line, and both
values — or `[OK]` if they agree. Exit code 1 means it found something.

```
[FIRST DIVERGENCE]  (earliest in execution order)
  file: lib/parser.rb   variable: total   line: 42
  CRuby : i:128         Spinel : i:-9223372036854775808
```

Covers scalar and string locals; arrays/hashes/objects are noted as not-compared
(value formatting for those is a known gap). If `bisect.sh` says `[OK]` but your
output still differs, the difference is in non-scalar state or output formatting.

## "Where did it crash / what's the backtrace?" → `--debug`

Compile with `--debug` and you get two things a normal Spinel binary lacks:

```sh
spinel app.rb --debug -o app
```

**Step through the Ruby** in a native debugger — breakpoints by Ruby line,
inspect locals by their Ruby name (`lv_<name>`):
```sh
lldb -o 'b app.rb:42' -o run -o 'p lv_total' -o 'bt' app
```
The backtrace shows your Ruby methods (`app.rb:in 'Parser#parse'`), across
`require_relative`'d files.

**Real `Exception#backtrace`.** Normally Spinel returns an empty backtrace; under
`--debug` an exception carries the actual call chain:
```ruby
begin
  risky
rescue => e
  puts e.backtrace   # app.rb:in `inner' / app.rb:in `outer' / app.rb:in `<main>'
end
```

`--debug` forces `-O0` and keeps methods as real frames; use `-g` if you want
debug info at your chosen `-O` level (less faithful stepping).

## "What types did Spinel infer?" → RBS + editor hover

Spinel infers a type for everything. Two ways to see it:

**As an `.rbs` file** (feeds Steep/Sorbet/ruby-lsp, and double-checks inference):
```sh
spinel app.rb --emit-rbs        # writes app.rbs
```
```ruby
class Planet
  @mass: Float
  def gravity_at: (Float) -> Float
end
def pick: (bool) -> untyped # spinel: widened to untyped (slow path)
```
**Read the `untyped`s.** Each one is either genuinely polymorphic code or a spot
where inference couldn't pin a type — i.e. the boxed slow path. If a method you
expected to be fast says `untyped`, that's your hint to make the types concrete
(annotate with RBS via `--rbs`, or simplify the code) before it bites.

**On hover, in your editor** — install the ruby-lsp addon
(`tools/ruby-lsp-spinel`, see its README): hover a call/ivar/constant to see
`**Spinel** infers Array[Integer]`, or a ⚠️ when it degraded to `untyped`.

## A worked loop

You ship a gem and want it `verified`. The smoke run diverges. Instead of
bisecting by hand:

1. `./bisect.sh smoke.rb` → `total @ lib/calc.rb:42  CRuby=128 Spinel=-92233…` —
   an overflow. You learn it's `total` accumulating past int64.
2. Decide: is the input really that large? If yes, the value genuinely needs
   Bignum — compile with `--int-overflow=promote` so Spinel matches CRuby.
3. Re-run `./bisect.sh` → `[OK]`. Keep `smoke.rb`; it's now a Spinel regression
   test stronger than a golden-output file.

## Quick reference

| I want to… | Command |
|---|---|
| check the binary matches CRuby | `bisect.sh app.rb` |
| pick overflow behavior | `SPINEL_INT_OVERFLOW=wrap\|promote bisect.sh app.rb` |
| step the Ruby in a debugger | `spinel app.rb --debug -o app && lldb … app` |
| get a real exception backtrace | compile `--debug` |
| see inferred signatures | `spinel app.rb --emit-rbs` |
| see types on hover | install `tools/ruby-lsp-spinel` |

For what's still missing to make these first-class in your workflow (packaging,
CI, richer editor support), see
[05-tooling-surfaces-and-roadmap.md](05-tooling-surfaces-and-roadmap.md).
