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

# Prefer --emit-types (POSITION granularity): a method can have a clean
# signature yet box internally (the Rails-view shape @rubys flagged on
# spinel-dev#5), which a method-boundary --emit-rbs scan misses. The untyped
# share at position level is a much truer "how much dynamism survives" signal.
# Fall back to --emit-rbs (signature granularity) if the engine predates
# --emit-types (#1298).
tmp = "#{src}.estimate.json"
granularity = "position (--emit-types)"
if system(SPINEL, src, "--emit-types", "-o", tmp, out: File::NULL, err: File::NULL) && File.size?(tmp)
  ts = (JSON.parse(File.read(tmp))["types"] rescue [])
  File.delete(tmp)
  abort "speedup-estimate: no inferred types (does it compile?)" if ts.empty?
  types     = ts.map { |t| t["type"].to_s }
  numeric   = types.count { |t| %w[int float bool].include?(t) }
  container = types.count { |t| t =~ /\A(.*array|.*hash|set|range)/i }
  untyped   = types.count { |t| t =~ /poly|untyped/ }
else
  rbs_path = "#{src}.estimate.rbs"
  system(SPINEL, src, "--emit-rbs", "-o", rbs_path, out: File::NULL, err: File::NULL)
  abort "speedup-estimate: neither --emit-types nor --emit-rbs produced output" unless File.size?(rbs_path)
  rbs = File.read(rbs_path); File.delete(rbs_path)
  granularity = "signature (--emit-rbs fallback — misses intra-method boxing)"
  sig = rbs.lines.select { |l| l =~ /^\s*def / }
  types     = sig.flat_map { |l| l.split(":", 2)[1].to_s.scan(/[A-Z][A-Za-z0-9_:]*|untyped|bool/) }
  numeric   = types.count { |t| %w[Integer Float bool].include?(t) }
  container = types.count { |t| t =~ /\A(Array|Hash|Set|Range)/ }
  untyped   = types.count("untyped")
end

untyped_ratio = types.empty? ? 0.0 : untyped.to_f / types.size
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
  file: src, granularity: granularity,
  type_positions: types.size, numeric: numeric, container: container, untyped: untyped,
  untyped_ratio: untyped_ratio.round(3), numeric_share: numeric_share.round(3),
  score: score.round(3), verdict: verdict,
}

if json
  puts JSON.generate(result)
else
  puts "speedup-estimate: #{src}"
  puts "  granularity        #{granularity}"
  puts "  type mix           numeric=#{numeric}  container=#{container}  untyped/poly=#{untyped}  / #{types.size} positions"
  puts "  untyped ratio      #{(untyped_ratio*100).round(1)}%   numeric share #{(numeric_share*100).round(1)}%"
  puts "  verdict            #{verdict}"
  puts
  puts "  (spike heuristic — static, no run. For 'why slow / how much of the time',"
  puts "   run spinel-perf.rb: it weights the poly positions by the hot-frame profile.)"
end
