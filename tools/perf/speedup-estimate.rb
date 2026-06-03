#!/usr/bin/env ruby
# frozen_string_literal: true
#
# SPIKE — static "would Spinel make this much faster?" estimate.
#
# Spinel compiles tight, monomorphically-typed, numeric code to clean C and wins
# big; it loses on polymorphic, dispatch-/container-heavy, dynamic code (every
# `untyped` slot is the boxed poly slow path — see matz/spinel#282). The cheapest
# proxy for "how much dynamism survives into the binary" is the inference itself:
# run `--emit-rbs` and look at how many signatures degraded to `untyped` and what
# the concrete types are (numeric vs container/string).
#
# This is a heuristic, not a measurement — a spike to see if the static signal
# tracks real speedups (validate against a benchmark corpus next). It reuses only
# `--emit-rbs`, which is upstream, so it runs against any current `spinel`.
#
# Usage:  SPINEL_DIR=~/sites/spinel ruby speedup-estimate.rb <program.rb>
#         (--json for machine output)

require "json"

SPINEL = File.join(ENV["SPINEL_DIR"] || File.expand_path("~/sites/spinel"), "spinel")
abort "speedup-estimate: #{SPINEL} not found (set SPINEL_DIR)" unless File.executable?(SPINEL)

json = ARGV.delete("--json")
src = ARGV[0] or abort "usage: speedup-estimate.rb [--json] <program.rb>"
abort "no such file: #{src}" unless File.file?(src)

rbs_path = "#{src}.estimate.rbs"
system(SPINEL, src, "--emit-rbs", "-o", rbs_path, out: File::NULL, err: File::NULL)
abort "speedup-estimate: --emit-rbs produced nothing (does it compile?)" unless File.size?(rbs_path)
rbs = File.read(rbs_path)
File.delete(rbs_path)

sig_lines = rbs.lines.select { |l| l =~ /^\s*def / }
methods   = sig_lines.size
degraded  = rbs.lines.count { |l| l.include?("# spinel: widened") }
# Count type tokens on the right of each `def ... :` signature.
types = sig_lines.flat_map { |l| l.split(":", 2)[1].to_s.scan(/[A-Z][A-Za-z0-9_:]*|untyped|bool/) }
numeric   = types.count { |t| %w[Integer Float bool].include?(t) }
container = types.count { |t| t =~ /\A(Array|Hash|Set|Range)/ }
untyped   = types.count("untyped")
concrete  = types.size - untyped

untyped_ratio = methods.zero? ? 0.0 : untyped.to_f / [types.size, 1].max
numeric_share = types.empty? ? 0.0 : numeric.to_f / types.size

# Heuristic score in [-1, 1]: numeric/concrete pushes toward "faster",
# untyped/container toward "slower".
score = numeric_share * 1.0 - untyped_ratio * 1.4 - (container.to_f / [types.size,1].max) * 0.4
verdict =
  if    untyped_ratio > 0.30 then "likely SLOWER — heavy poly/untyped (dispatch-bound, cf. #282)"
  elsif score > 0.35         then "likely MUCH faster — concrete, numeric-dominant"
  elsif score > 0.0          then "likely faster — mostly concrete types"
  else                            "marginal / uncertain — mixed; measure to be sure"
  end

result = {
  file: src, methods: methods, degraded_methods: degraded,
  type_tokens: types.size, numeric: numeric, container: container, untyped: untyped,
  untyped_ratio: untyped_ratio.round(3), numeric_share: numeric_share.round(3),
  score: score.round(3), verdict: verdict,
}

if json
  puts JSON.generate(result)
else
  puts "speedup-estimate: #{src}"
  puts "  methods            #{methods}  (#{degraded} degraded to untyped)"
  puts "  type mix           numeric=#{numeric}  container=#{container}  untyped=#{untyped}  / #{types.size} tokens"
  puts "  untyped ratio      #{(untyped_ratio*100).round(1)}%   numeric share #{(numeric_share*100).round(1)}%"
  puts "  verdict            #{verdict}"
  puts
  puts "  (spike heuristic — static proxy via --emit-rbs degrade scan; validate vs a benchmark corpus)"
end
