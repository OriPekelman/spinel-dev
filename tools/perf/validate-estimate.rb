#!/usr/bin/env ruby
# frozen_string_literal: true
#
# SPIKE — does the static speedup-estimate track real Spinel-vs-CRuby speedups?
#
# For each benchmark: compile with Spinel (-O2), wall-time it vs CRuby (best of N),
# and run speedup-estimate. Tabulate the measured ratio against the static score
# and eyeball the correlation. Corpus defaults to Spinel's own `benchmark/`
# (compilable by construction); pass paths to override.
#
# Usage: SPINEL_DIR=~/sites/spinel ruby validate-estimate.rb [bench1.rb ...]

require "json"

SPINEL_DIR = ENV["SPINEL_DIR"] || File.expand_path("~/sites/spinel")
SPINEL = File.join(SPINEL_DIR, "spinel")
HERE = __dir__
RUNS = 3

abort "no spinel at #{SPINEL}" unless File.executable?(SPINEL)

# A representative subset spanning Spinel's sweet spot and its weak spot.
DEFAULT = %w[
  bm_fib bm_nbody bm_mandel_term bm_matmul bm_nqueens bm_fannkuch bm_ackermann
  bm_micro_lisp bm_json_parse bm_fasta bm_huffman bm_binary_trees
  bm_ao_render bm_gcbench bm_life bm_linked_list bm_csv_process bm_huffman
].uniq.map { |n| File.join(SPINEL_DIR, "benchmark", "#{n}.rb") }

benches = ARGV.empty? ? DEFAULT.select { |f| File.file?(f) } : ARGV

# Spinel binaries start instantly; CRuby pays ~25ms of interpreter startup. On a
# sub-100ms benchmark that startup *is* the measured "speedup" and says nothing
# about the compiled code. Measure each runtime's baseline (an empty program) and
# subtract it, so the ratio reflects *compute*, not process launch.
def baseline_setup
  empty = "/tmp/_sp_empty.rb"
  File.write(empty, "x = 1\n")
  bin = "/tmp/_sp_empty.spbin"
  system(SPINEL, empty, "-o", bin, out: File::NULL, err: File::NULL)
  [empty, bin]
end

def best_time(cmd)
  best = nil
  RUNS.times do
    t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    ok = system(*cmd, out: File::NULL, err: File::NULL)
    t1 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    return nil unless ok
    dt = t1 - t0
    best = dt if best.nil? || dt < best
  end
  best
end

empty_src, empty_bin = baseline_setup
cruby_base = best_time(["ruby", empty_src]) || 0.0
spin_base  = best_time([empty_bin]) || 0.0
warn "baselines: cruby startup=%.3fs  spinel startup=%.3fs" % [cruby_base, spin_base]

rows = []
benches.each do |src|
  name = File.basename(src, ".rb").sub(/^bm_/, "")
  bin = "/tmp/#{name}.spbin"
  unless system(SPINEL, src, "-o", bin, out: File::NULL, err: File::NULL) && File.executable?(bin)
    rows << { name: name, note: "did not compile" }; next
  end
  cruby = best_time(["ruby", src])
  spin  = best_time([bin])
  File.delete(bin) if File.exist?(bin)
  next unless cruby && spin
  c_compute = cruby - cruby_base
  s_compute = spin - spin_base
  # Need real compute on the CRuby side to say anything; and avoid /0.
  dominated = c_compute < 0.05
  ratio = dominated ? nil : (c_compute / [s_compute, 0.0005].max)
  est = JSON.parse(`SPINEL_DIR=#{SPINEL_DIR} ruby #{File.join(HERE, "speedup-estimate.rb")} --json #{src} 2>/dev/null`) rescue {}
  rows << {
    name: name, cruby: cruby, spin: spin, c_compute: c_compute, s_compute: s_compute,
    ratio: ratio, dominated: dominated,
    score: est["score"], untyped: est["untyped_ratio"], verdict: (est["verdict"] || "?")[/\b(MUCH faster|faster|SLOWER|marginal|uncertain)\b/i] || "?",
  }
end
File.delete(empty_src) rescue nil; File.delete(empty_bin) rescue nil

ok = rows.reject { |r| r[:note] }
measurable = ok.reject { |r| r[:dominated] }
printf "%-14s %10s %10s %8s %7s %8s  %s\n", "bench", "cpu cruby", "cpu spin", "x faster", "score", "untyped", "estimate"
measurable.sort_by { |r| -r[:ratio] }.each do |r|
  printf "%-14s %9.3fs %9.3fs %8.1f %7.2f %7.1f%%  %s\n",
         r[:name], r[:c_compute], r[:s_compute], r[:ratio], (r[:score] || 0), ((r[:untyped] || 0) * 100), r[:verdict]
end
ok.select { |r| r[:dominated] }.each { |r| printf "%-14s  (startup-dominated: %.0fms compute — too light to measure)\n", r[:name], r[:c_compute]*1000 }
rows.select { |r| r[:note] }.each { |r| printf "%-14s  (%s)\n", r[:name], r[:note] }

# Rank correlation on the measurable benchmarks only.
scored = measurable.select { |r| r[:score] }
if scored.size >= 3
  by_score = scored.sort_by { |r| r[:score] }.each_with_index.to_h { |r, i| [r[:name], i] }
  by_ratio = scored.sort_by { |r| r[:ratio] }.each_with_index.to_h { |r, i| [r[:name], i] }
  n = scored.size
  d2 = scored.sum { |r| (by_score[r[:name]] - by_ratio[r[:name]])**2 }
  rho = 1.0 - (6.0 * d2) / (n * (n * n - 1))
  puts
  printf "Spearman rank correlation (static score vs measured speedup): %.2f  (n=%d)\n", rho, n
  puts "  +1 = the estimate perfectly orders benchmarks by real speedup; 0 = no signal."
end
