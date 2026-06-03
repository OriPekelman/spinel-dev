# frozen_string_literal: true

Gem::Specification.new do |spec|
  spec.name        = "spinel-doctor"
  spec.version     = "0.1.0"
  spec.authors     = ["Ori Pekelman"]
  spec.summary     = "One-shot risk report for compiling a program with Spinel"
  spec.description = <<~DESC
    Runs the cheap-to-expensive battery and says, in one place, everything risky
    about compiling a program with the Spinel AOT Ruby compiler: a compile-probe
    (unresolved calls that silently emit 0), an inference-degrade scan (methods
    widened to the boxed `untyped` slow path), and a behavior check via
    differential value-bisection (or single-sided for FFI/AOT-only apps). Human
    or `--json`. Needs a `spinel` checkout (SPINEL_DIR); the behavior leg uses
    spinel-bisect.
  DESC
  spec.homepage      = "https://github.com/OriPekelman/spinel-dev"
  spec.license       = "MIT"
  spec.required_ruby_version = ">= 3.1"

  spec.files       = %w[doctor.sh README.md]
  spec.bindir      = "exe"
  spec.executables = %w[spinel-doctor]
  spec.require_paths = ["."]

  spec.add_dependency "spinel-bisect", ">= 0.1.0"

  spec.metadata = {
    "source_code_uri" => "https://github.com/OriPekelman/spinel-dev/tree/main/tools/doctor",
    "rubygems_mfa_required" => "true",
  }
end
