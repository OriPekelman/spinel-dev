#!/usr/bin/env ruby
# frozen_string_literal: true
#
# SPIKE — "why is my Spinel app slow / what's slow?", per Ruby LINE.
#
# Compiles with `#line` directives + gprof instrumentation (-g -pg -O2), runs it,
# and reads gprof's *line-level* flat profile. Because the `#line` build's line
# table points back at the `.rb`, each hot sample lands on a real Ruby
# `(file, line)` — which we de-mangle to a method, print with the source text,
# and overlay against the inference degrade scan. "What's slow" (the hot lines)
# and "why" (the ones on the boxed poly slow path) land together.
#
# Uses gprof (`perf` is locked down at perf_event_paranoid=4 here). Caveats: -O2
# inlines small methods (attributed to the inline site); gprof samples at 10ms so
# short workloads give coarse %, run a heavy input.
#
# Usage: SPINEL_DIR=~/sites/spinel ruby spinel-perf.rb [--json] <program.rb> [-- args...]

require "tmpdir"
require "json"

SPINEL_DIR = ENV["SPINEL_DIR"] || File.expand_path("~/sites/spinel")
SPINEL = File.join(SPINEL_DIR, "spinel")
CC = ENV["CC"] || "cc"
OVF = { "raise" => "-DSP_INT_OVERFLOW_MODE_RAISE", "wrap" => "-DSP_INT_OVERFLOW_MODE_WRAP",
        "promote" => "-DSP_INT_OVERFLOW_MODE_PROMOTE" }[ENV["SPINEL_INT_OVERFLOW"] || "raise"]
abort "no spinel at #{SPINEL}" unless File.executable?(SPINEL)

RUNTIME_PFX = /\A(int_|str_|float_|sym_|gc_|bigint|sprintf|raise|exc_|range|utf8|oom|bt_|
  backtrace|caller|StrArray|IntArray|FloatArray|PtrArray|PolyArray|Str|Int|Float|Hash|Range|
  Complex|Rational|Sym|alloc|free|to_s|dup|new|pack|unpack|regex|re_|idiv|imod|gcd|fdiv|ipow|
  json|String|Array|main\b)/x

def demangle(sym) # sp_<Class>_<method> -> Class#method / Class.method / bare
  return nil unless sym&.start_with?("sp_")
  name = sym[3..]
  return :runtime if name =~ RUNTIME_PFX
  mstart = nil
  name.chars.each_with_index { |c, i| (mstart = i; break) if (i.zero? || name[i-1] == "_") && c =~ /[a-z]/ }
  return name unless mstart
  return (name.start_with?("cls_") ? name[4..] : name) if mstart.zero?
  meth = name[mstart..]; sep = "#"
  if meth.start_with?("cls_") then meth = meth[4..]; sep = "." end
  "#{name[0...(mstart-1)].gsub('_', '::')}#{sep}#{meth}"
end

json = !!ARGV.delete("--json")
src = ARGV.shift or abort "usage: spinel-perf.rb [--json] <program.rb> [-- args...]"
ARGV.shift if ARGV.first == "--"
prog_args = ARGV
src_lines = (File.readlines(src, chomp: true) rescue [])

Dir.mktmpdir("spinel_perf") do |w|
  cfile = File.join(w, "out.c")
  # `-g -c`: emit C *with* #line directives so gprof -l maps samples to the .rb.
  unless system(SPINEL, "-g", src, "-c", "-o", cfile, out: File::NULL, err: File::NULL) && File.size?(cfile)
    abort "spinel-perf: codegen failed (does it compile? try `spinel doctor`)"
  end
  c = File.read(cfile)
  links  = c.scan(%r{^/\* SPINEL_LINK: (.*) \*/$}).flatten.join(" ")
  cflags = c.scan(%r{^/\* SPINEL_CFLAGS: (.*) \*/$}).flatten.join(" ")
  bin = File.join(w, "prof")
  cc = "#{CC} -pg -g -O2 -Wno-all -I#{SPINEL_DIR}/lib -I#{SPINEL_DIR}/lib/regexp #{cflags} " \
       "#{cfile} #{SPINEL_DIR}/lib/libspinel_rt.a -lm #{OVF} #{links} -o #{bin}"
  unless system("#{cc} 2>#{w}/cc.err")
    abort "spinel-perf: C build failed\n" + File.read("#{w}/cc.err").lines.grep(/error|@[A-Z_]+@/).first(4).join
  end
  # gprof samples at 10ms, so one short run is noisy (different hot lines each
  # time). Run a few times and sum the profiles (gprof accepts many gmon files)
  # to stabilize the ranking. Override with SPINEL_PERF_RUNS.
  runs = (ENV["SPINEL_PERF_RUNS"] || "5").to_i
  gmons = []
  runs.times do |i|
    Dir.chdir(w) { system(bin, *prog_args, out: File::NULL, err: File::NULL) }
    g = File.join(w, "gmon.out")
    break unless File.file?(g)
    dst = File.join(w, "gmon.#{i}"); File.rename(g, dst); gmons << dst
  end
  abort "spinel-perf: no gmon.out — workload too short to sample; use a heavier input." if gmons.empty?

  # Degrade set (methods whose --emit-rbs signature widened to untyped).
  rbs = File.join(w, "x.rbs"); degraded = {}
  system(SPINEL, src, "--emit-rbs", "-o", rbs, out: File::NULL, err: File::NULL)
  if File.size?(rbs)
    File.foreach(rbs) do |l|
      next unless l.include?("untyped")
      r = demangle("sp_#{$1}") if l =~ /^\s*def\s+([A-Za-z_]\w*)\s*:/
      degraded[r] = true if r.is_a?(String)
    end
  end

  base = File.basename(src)
  lines = Hash.new(0.0)   # [ruby_method, lineno] -> self%
  runtime_pct = 0.0
  # gprof -l flat rows:  "%  cum  self  [calls ns ns]  sp_fn (file.rb:NN @ addr)"
  `gprof -l -p -b #{bin} #{gmons.join(' ')} 2>/dev/null`.each_line do |ln|
    next unless ln =~ /^\s*(\d+\.\d+)\s+[\d.]+\s+[\d.]+\s+.*?\b(sp_\w+)\s+\((\S+?):(\d+)\s+@/
    pct = $1.to_f; fn = $2; file = $3; lineno = $4.to_i
    r = demangle(fn)
    if r == :runtime || !r.is_a?(String) || file !~ /#{Regexp.escape(base)}/
      runtime_pct += pct; next
    end
    lines[[r, lineno]] += pct
  end

  # Per-method rollup is stable across runs; per-line is sample-limited (gprof's
  # 10ms granularity jitters the exact line on short workloads). Lead with the
  # stable signal, show lines as detail.
  by_method = Hash.new(0.0)
  lines.each { |(m, _), v| by_method[m] += v }
  methods = by_method.sort_by { |_, v| -v }.first(10)
  ranked = lines.sort_by { |_, v| -v }.first(12)

  if json
    out = { file: src, runtime_pct: runtime_pct.round(1), runs: gmons.size,
            methods: methods.map { |m, p| { method: m, self_pct: p.round(1), slow_path: !!degraded[m] } },
            lines: ranked.map { |(m, l), p| { method: m, line: l, self_pct: p.round(1),
              source: src_lines[l-1]&.strip, slow_path: !!degraded[m] } } }
    puts JSON.generate(out); next
  end

  puts "spinel-perf: #{src}   (gprof -l, #line + -pg -O2, #{gmons.size} runs summed)"
  puts "  ~%.0f%% of self-time is runtime/GC/inlined; user code below. ⚠ = on poly slow path.\n\n" % runtime_pct
  puts "  hot methods (self-time, stable):"
  methods.each { |m, pct| printf "  %5.1f%%  %s%s\n", pct, (degraded[m] ? "⚠ " : "  "), m }
  puts "\n  hot lines (sample-limited — gprof 10ms; heavier workload = finer):"
  ranked.each do |(m, l), pct|
    printf "  %5.1f%%  %-24s %-9s %s\n", pct, m, "#{base}:#{l}", (src_lines[l-1]&.strip || "")[0, 44]
  end
  if (hs = methods.select { |m, _| degraded[m] }).any?
    puts "\n  → hot + on the poly slow path: #{hs.first(3).map(&:first).join(', ')}"
    puts "    (un-inferred dynamism costing you — type those to speed up.)"
  end
  puts "\n  (spike — gprof's per-line is coarse on short runs; perf would sharpen it but is\n   locked down here. --emit-types (#1298) would make the ⚠ per-line, not per-method.)"
end
