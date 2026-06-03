# frozen_string_literal: true

Gem::Specification.new do |spec|
  spec.name        = "spinel-bisect"
  spec.version     = "0.1.0"
  spec.authors     = ["Ori Pekelman"]
  spec.summary     = "Differential value-bisection for the Spinel AOT Ruby compiler"
  spec.description = <<~DESC
    Localizes a Spinel silent miscompile to a (file, line, variable): runs a
    program under CRuby (the oracle) and as a Spinel --debug build, traces the
    change-history of every scalar / string / array / hash / bignum local on each
    side, and reports the first to diverge (or an output-diff / crash site when it
    doesn't land in a local). `spinel-triage` localizes a whole failing suite.

    Polyglot by necessity — the lldb trace is Python — so it shells out to its
    bundled sh/python/ruby scripts; runtime prerequisites: a `spinel` checkout
    (point at it with SPINEL_DIR), python3, and lldb.
  DESC
  spec.homepage      = "https://github.com/OriPekelman/spinel-dev"
  spec.license       = "MIT"
  spec.required_ruby_version = ">= 3.1"

  spec.files = %w[bisect.sh triage.sh compare.py cruby_trace.rb spinel_lldb_trace.py README.md] +
               Dir["examples/**/*"]
  spec.bindir      = "exe"
  spec.executables = %w[spinel-bisect spinel-triage]
  spec.require_paths = ["."]

  spec.metadata = {
    "source_code_uri"   => "https://github.com/OriPekelman/spinel-dev/tree/main/tools/value-bisect",
    "rubygems_mfa_required" => "true",
  }
end
