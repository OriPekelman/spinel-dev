# frozen_string_literal: true

Gem::Specification.new do |spec|
  spec.name = "ruby-lsp-spinel"
  spec.version = "0.1.0"
  spec.authors = ["Ori Pekelman"]
  spec.summary = "Surface Spinel's inferred types and degrade warnings in the editor"
  spec.description = <<~DESC
    A ruby-lsp addon that shows the Spinel AOT compiler's whole-program type
    inference on hover, and warns where a value degraded to the boxed `untyped`
    (poly) slow path — the silent-miscompile signal. Backed by
    `spinel <file> --emit-types`.
  DESC
  spec.homepage = "https://github.com/OriPekelman/spinel"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.1"

  spec.files = Dir["lib/**/*.rb", "README.md"]
  spec.require_paths = ["lib"]

  # ruby-lsp discovers addons by requiring ruby_lsp/**/addon.rb from gems in
  # the bundle; declare it so the addon API is present.
  spec.add_dependency("ruby-lsp", ">= 0.23")
end
