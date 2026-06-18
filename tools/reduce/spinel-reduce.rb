#!/usr/bin/env ruby
# frozen_string_literal: true
#
# SPIKE — spinel-reduce: delta-debug a degrading program to its minimal trigger
# (spinel-dev#9 proposal 5).
#
# Upstream now ships a first-party `spinel-reduce` for the basic case (ddmin a
# compile failure). This one is the specialized layer on top: it reduces against
# `doctor`'s SEMANTIC findings (inference↔codegen disagreement, widened slot, the
# failing C symbol), adds --shrink-ints size-threshold parameter search, and runs
# on FFI/AOT apps via --no-cruby. See tools/reduce/README.md for when to use which.
#
# A size-/complexity-triggered Spinel degrade (an emit-0, an inference↔codegen
# disagreement, a widened slot) is brutal to localize by hand — you bisect dims,
# requires, ivar count, FFI-call count. This automates it: ddmin (delta
# debugging) over the source lines, with `spinel doctor --json` as the oracle.
# Keep removing chunks as long as the *target finding still reproduces*; stop at a
# 1-minimal program. What survives the reduction *is* the cause.
#
# The target is a specific finding from the original program's doctor report —
# by default the first inference↔codegen disagreement (the silent-miscompile
# fingerprint), else the first unresolved call, else the first widened method.
# Override with `--target <substring>`.
#
# Usage:
#   SPINEL_DIR=~/sites/spinel ruby spinel-reduce.rb [--target SUBSTR] \
#       [--no-cruby] [--keep-bisect] [-o min.rb] <degrading.rb>
#     --no-cruby      FFI/AOT-only app (single-sided doctor behavior leg)
#     --keep-bisect   also require the behavior verdict to reproduce (slow; for
#                     targeting a confirmed miscompile rather than a static finding)
#     -o FILE         write the minimized program here (default: stdout)

require "json"
require "tmpdir"
require "open3"
require "digest"

HERE   = File.expand_path(__dir__)
DOCTOR = File.expand_path(File.join(HERE, "..", "doctor", "doctor.sh"))
SPINEL_DIR = ENV["SPINEL_DIR"] || File.expand_path("~/sites/spinel")
abort "spinel-reduce: doctor.sh not found at #{DOCTOR}" unless File.exist?(DOCTOR)

# ---- args ----
opts = { target: nil, no_cruby: false, keep_bisect: false, out: nil }
argv = ARGV.dup
until argv.empty?
  a = argv.shift
  case a
  when "--target"      then opts[:target] = argv.shift
  when "--no-cruby"    then opts[:no_cruby] = true
  when "--keep-bisect" then opts[:keep_bisect] = true
  when "--shrink-ints" then opts[:shrink_ints] = true
  when "-o"            then opts[:out] = argv.shift
  when /\A--/          then abort "spinel-reduce: unknown flag #{a}"
  else opts[:src] = a
  end
end
src = opts[:src] or abort "usage: spinel-reduce.rb [--target SUBSTR] [--no-cruby] [-o min.rb] <file.rb>"
abort "no such file: #{src}" unless File.file?(src)

$calls = 0
$cache = {}

# Run doctor on a candidate file, return the flat list of finding strings
# (disagreements + unresolved calls + widened methods + a behavior verdict tag).
def doctor_findings(path, opts)
  cmd = ["/bin/sh", DOCTOR, "--json"]
  cmd << "--no-bisect" unless opts[:keep_bisect]
  cmd << "--no-cruby" if opts[:no_cruby]
  cmd << path
  $calls += 1
  out, _err, _st = Open3.capture3({ "SPINEL_DIR" => SPINEL_DIR }, *cmd)
  rep = (JSON.parse(out) rescue {})
  f = []
  cg = rep["codegen"]
  if cg
    sym = cg["symbol"].to_s.strip
    f << (sym.empty? ? "codegen #{cg['error_class']}" : "codegen #{cg['error_class']} #{sym}")
    f << cg["message"].to_s unless cg["message"].to_s.empty?
  end
  f.concat(rep["disagreements"] || [])
  f.concat(rep.dig("compile", "ignored_requires") || [])
  f.concat(rep.dig("compile", "unresolved_calls") || [])
  f.concat(rep.dig("inference", "degraded_methods") || [])
  b = rep["behavior"]
  v = b.is_a?(Hash) ? b["verdict"] : b
  f << "behavior:#{v}" if %w[diverge output-differ crash abort].include?(v)
  f
end

# Does this candidate (array of source lines) still reproduce the target? A fast
# `ruby -c` syntax gate first, so obviously-broken reductions skip the (slow)
# spinel compile.
def triggers?(lines, target, opts)
  key = Digest::SHA1.hexdigest(lines.join)
  return $cache[key] if $cache.key?(key)
  result = false
  Dir.mktmpdir("spinel_reduce") do |w|
    cand = File.join(w, File.basename(opts[:src]))
    File.write(cand, lines.join)
    if system("ruby", "-c", cand, out: File::NULL, err: File::NULL)
      result = doctor_findings(cand, opts).any? { |fnd| fnd.include?(target) }
    end
  end
  $cache[key] = result
end

# Top-level balanced blocks (`def`/`class`/`module` at column 0 … column-0 `end`).
# Conventional indentation; lets us drop whole unrelated methods/classes
# atomically — which line-ddmin can't, since removing any single line of a
# `class … end` breaks syntax (the residual-block problem).
def toplevel_blocks(lines)
  ranges = []
  i = 0
  while i < lines.size
    if lines[i] =~ /\A(def|class|module)\b/
      k = i + 1
      k += 1 while k < lines.size && lines[k].rstrip != "end"
      ranges << [i, k] if k < lines.size
      i = k + 1
    else
      i += 1
    end
  end
  ranges
end

# Remove whole top-level blocks while the target survives (largest churn first).
def block_reduce(lines, target, opts)
  changed = true
  while changed
    changed = false
    toplevel_blocks(lines).each do |st, en|
      cand = lines[0...st] + (lines[(en + 1)..] || [])
      next if cand.empty?
      if triggers?(cand, target, opts)
        lines = cand
        changed = true
        $stderr.printf "  block-removed (cols %d-%d) -> %d lines (%d doctor calls)\n", st + 1, en + 1, lines.size, $calls
        break
      end
    end
  end
  lines
end

# Classic ddmin (complement removal): converges to a 1-minimal set.
def ddmin(lines, target, opts)
  n = 2
  while lines.size >= 2
    chunk = (lines.size.to_f / n).ceil
    removed = false
    start = 0
    while start < lines.size
      cand = lines[0...start] + (lines[(start + chunk)..] || [])
      if !cand.empty? && triggers?(cand, target, opts)
        lines = cand
        n = [n - 1, 2].max
        removed = true
        $stderr.printf "  reduced to %d lines  (%d doctor calls)\n", lines.size, $calls
        break
      end
      start += chunk
    end
    next if removed
    break if n >= lines.size
    n = [n * 2, lines.size].min
  end
  lines
end

# Parameter-search axis (--shrink-ints): code reduction isolates *which* code is
# the trigger; this isolates the *numeric threshold* of a size-triggered degrade
# ("fails when the dim crosses ~512"). For each integer literal, binary-search the
# smallest value that still reproduces the target — the boundary the user couldn't
# pin by hand. A literal whose value doesn't matter (even 0 still triggers) is
# reported as "not size-dependent" and zeroed. (Assumes the trigger is monotone in
# the value, which is what a size threshold is.)
INT_LIT = /(?<![\w.])\d[\d_]*(?![\w.])/

def shrink_ints(lines, target, opts, src)
  thresholds = []
  li = 0
  while li < lines.size
    matches = lines[li].enum_for(:scan, INT_LIT).map { Regexp.last_match }
    matches.reverse_each do |m|
      orig_v = m[0].delete("_").to_i
      next if orig_v == 0
      b, e = m.begin(0), m.end(0)
      test_v = lambda do |v|
        cand = lines.dup
        cand[li] = lines[li][0...b] + v.to_s + lines[li][e..]
        triggers?(cand, target, opts)
      end
      label = "#{File.basename(src)}:#{li + 1}"
      if test_v.call(0)                       # value is irrelevant to the target
        lines[li] = lines[li][0...b] + "0" + lines[li][e..]
        thresholds << "#{label}: #{orig_v} → 0  (not size-dependent)"
        next
      end
      lo, hi = 1, orig_v                       # orig_v triggers; find the smallest that does
      while lo < hi
        mid = (lo + hi) / 2
        if test_v.call(mid) then hi = mid else lo = mid + 1 end
      end
      lines[li] = lines[li][0...b] + hi.to_s + lines[li][e..]
      thresholds << "#{label}: #{orig_v} → #{hi}  (threshold — #{hi - 1} does not trigger)"
    end
    li += 1
  end
  [lines, thresholds]
end

# ---- pick the target ----
orig = File.readlines(src) # keep line endings
base = doctor_findings(src, opts)
codegen  = base.select { |f| f.start_with?("codegen ") }
disagree = base.select { |f| f.include?(" on ") && f.include?("[") }
unresolved = base.select { |f| f.start_with?("cannot resolve") }
widened = base.reject { |f| codegen.include?(f) || disagree.include?(f) || unresolved.include?(f) || f.start_with?("behavior:") }

# Severity order for the default target: a codegen build failure (the #10 case)
# is the most actionable, then the disagreement fingerprint, then emit-0s, then a
# widened slot. The codegen target is the failing C *symbol* (stable across the
# reduction), not the whole message.
target =
  if opts[:target] then opts[:target]
  elsif !codegen.empty?    then codegen.first.split.last
  elsif !disagree.empty?   then disagree.first.split("  [").first.strip
  elsif !unresolved.empty? then unresolved.first.sub(/^warning:\s*/, "").strip
  elsif !widened.empty?    then widened.first.strip
  else nil
  end

if target.nil?
  abort "spinel-reduce: the program shows no degrade to reduce (doctor is clean).\n" \
        "  Pass --target <substring> if you're chasing a specific finding."
end
$stderr.puts "spinel-reduce: #{src}  (#{orig.size} lines)"
$stderr.puts "  target finding: #{target.inspect}"
unless triggers?(orig, target, opts)
  abort "spinel-reduce: target #{target.inspect} not reproduced on the unmodified file — refine --target."
end

# Structural pass first (drop whole unrelated blocks atomically), then line-level
# ddmin to clean up the remainder, then one more block pass for anything newly
# isolated.
min = block_reduce(orig, target, opts)
min = ddmin(min, target, opts)
min = block_reduce(min, target, opts)

int_thresholds = []
if opts[:shrink_ints]
  $stderr.puts "  shrinking integer literals (parameter search)…"
  min, int_thresholds = shrink_ints(min, target, opts, src)
end

# ---- output ----
text = min.join
text += "\n" unless text.end_with?("\n")
if opts[:out]
  File.write(opts[:out], text)
  $stderr.puts "\n  → wrote #{opts[:out]}  (#{orig.size} → #{min.size} lines, #{$calls} doctor calls)"
else
  $stderr.puts "\n  minimized (#{orig.size} → #{min.size} lines, #{$calls} doctor calls):\n\n"
  puts text
end
unless int_thresholds.empty?
  $stderr.puts "  size thresholds (parameter search):"
  int_thresholds.each { |t| $stderr.puts "    #{t}" }
end
$stderr.puts "  the surviving lines are the minimal trigger for: #{target.inspect}"
