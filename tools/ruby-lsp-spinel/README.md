# ruby-lsp-spinel

A [ruby-lsp](https://github.com/Shopify/ruby-lsp) addon that surfaces the
**Spinel** AOT compiler's whole-program type inference in your editor:

- **Hover** over a method call, instance variable, or constant to see the type
  Spinel inferred there (rendered as RBS — `Integer`, `Array[String]`, …).
- **Degrade warning**: when Spinel inferred `untyped`, the hover flags it as a
  **boxed poly slow path** — the silent-miscompile signal `spinelgems` warns
  about (it compiled, but a value quietly fell off the fast typed path).

It's the editor-facing half of Spinel's "make the inference visible" tooling;
the other half is `spinel app.rb --emit-rbs`, which dumps the same signatures as
an `.rbs` file for Steep/Sorbet.

## How it works

```
your .rb ──► spinel <file> --emit-types ──► JSON {types, diagnostics}
                                              │  (per-node file:line:col → type)
ruby-lsp hover ──► Spinel::TypeIndex.type_at(file, line, col) ──► hover text
```

Positions use Prism's `node.location` convention (1-based line, 0-based column),
exactly what `--emit-types` emits, so a hovered Prism node maps to a type record
with no translation. Results are cached per file and refreshed on change (mtime).

## Requirements

- The `spinel` compiler on `PATH` (or set `SPINEL_BIN=/path/to/spinel`), built so
  that `spinel <file> --emit-types` works (run `make` in the Spinel checkout).
- `ruby-lsp >= 0.23`.

## Install

Add to your project's `Gemfile` (ruby-lsp loads addons from the bundle):

```ruby
group :development do
  gem "ruby-lsp", require: false
  gem "ruby-lsp-spinel", require: false, path: "/path/to/spinel-dev/tools/ruby-lsp-spinel"
end
```

Restart the Ruby LSP server. Hover over a call/ivar/constant in a Spinel program.

## Limitations (v1)

- **Hover targets** are limited to the node kinds ruby-lsp's hover request
  recognizes (calls, instance/class/global variables, constants, strings,
  symbols). Bare local-variable reads aren't hover targets in ruby-lsp, so they
  won't show a type — hover the call or write instead.
- **Degrade surfacing is via hover**, not squiggly diagnostics: ruby-lsp 0.26
  has no addon extension point for push diagnostics. The `--emit-types` JSON
  still contains a structured `diagnostics` array (methods whose param/return
  widened to `untyped`) for other consumers and future ruby-lsp versions.
- **Whole-program**: `--emit-types` infers from the file as a program entry.
  Opening a `require_relative`'d helper in isolation may not type-check on its
  own; positions for required files use Spinel's multi-file source map.
- One `spinel` run per file change. With the native compiler binaries built,
  that's sub-second on typical files; the addon degrades to "no info" if the run
  fails (e.g. a compile error in the file) rather than erroring.

## Development

```sh
MT_NO_PLUGINS=1 ruby -Ilib test/test_addon.rb
```

The core (`lib/spinel/type_index.rb`) is editor-agnostic and unit-tested; the
integration tests drive the real ruby-lsp hover dispatcher to verify the glue.
`MT_NO_PLUGINS=1` avoids unrelated globally-installed minitest plugins.
