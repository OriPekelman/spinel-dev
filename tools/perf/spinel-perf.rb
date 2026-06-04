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

# GC frames: the precise collector core (sp_gc_mark/roots/...) and the
# per-class precise scanners spinel generates (`sp_<Class>_gc_scan`). The latter
# would otherwise mis-demangle to a fake user method (`Class#gc_scan`), so it
# has to be caught here, before the user-method path. GC self-time is its own
# bucket — a flat-across-workload ceiling (Q3, spinel-dev#5) reads as collector
# pause, which is exactly these frames.
GC_FRAME = /\Asp_gc_\w|_gc_scan\b/

def demangle(sym) # sp_<Class>_<method> -> Class#method / Class.method / bare
  return nil unless sym&.start_with?("sp_")
  return :gc if sym =~ GC_FRAME
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

  base = File.basename(src)
  # Degrade overlay. Prefer --emit-types (POSITION-keyed): a method can have a
  # clean signature yet box internally — the Rails-view shape @rubys flagged
  # (spinel-dev#5), which a method-boundary scan misses. Fall back to --emit-rbs
  # (method-granularity) if the engine predates --emit-types (#1298).
  poly_line = {}      # lineno -> true   (position granularity, preferred)
  poly_meth = {}      # ruby method -> true  (signature granularity, fallback)
  overlay = :rbs
  tjson = File.join(w, "x.json")
  if system(SPINEL, src, "--emit-types", "-o", tjson, out: File::NULL, err: File::NULL) && File.size?(tjson)
    (JSON.parse(File.read(tjson))["types"] rescue []).each do |t|
      next unless t["type"].to_s.downcase =~ /poly|untyped/
      poly_line[t["line"]] = true if File.basename(t["file"].to_s) == base
    end
    overlay = :types
  else
    rbs = File.join(w, "x.rbs")
    system(SPINEL, src, "--emit-rbs", "-o", rbs, out: File::NULL, err: File::NULL)
    File.foreach(rbs) { |l| (r = demangle("sp_#{$1}")) && (poly_meth[r] = true) if File.size?(rbs) && l.include?("untyped") && l =~ /^\s*def\s+([A-Za-z_]\w*)\s*:/ } if File.size?(rbs)
  end
  # Is the hot (method, line) on the boxed slow path? Per-line when we have it.
  is_poly = ->(m, l) { overlay == :types ? !!poly_line[l] : !!poly_meth[m] }

  lines = Hash.new(0.0)   # [ruby_method, lineno] -> self%
  runtime_pct = 0.0
  gc_pct = 0.0            # Q3: GC self-time, separated from generic runtime
  # gprof -l flat rows:  "%  cum  self  [calls ns ns]  sp_fn (file.rb:NN @ addr)"
  `gprof -l -p -b #{bin} #{gmons.join(' ')} 2>/dev/null`.each_line do |ln|
    next unless ln =~ /^\s*(\d+\.\d+)\s+[\d.]+\s+[\d.]+\s+.*?\b(sp_\w+)\s+\((\S+?):(\d+)\s+@/
    pct = $1.to_f; fn = $2; file = $3; lineno = $4.to_i
    r = demangle(fn)
    if r == :gc
      gc_pct += pct; next
    elsif r == :runtime || !r.is_a?(String) || file !~ /#{Regexp.escape(base)}/
      runtime_pct += pct; next
    end
    lines[[r, lineno]] += pct
  end

  # Per-method rollup is stable across runs; per-line is sample-limited (gprof's
  # 10ms granularity jitters the exact line). Lead with the stable signal.
  by_method = Hash.new(0.0)
  lines.each { |(m, _), v| by_method[m] += v }
  methods = by_method.sort_by { |_, v| -v }.first(10)
  ranked = lines.sort_by { |_, v| -v }.first(12)

  # THE metric @rubys's Q2 asks for: of the user self-time, how much is on the
  # boxed slow path (hot ∧ poly)? Not poly-anywhere — poly *where it's hot*.
  user_pct = lines.values.sum
  hot_poly_pct = lines.sum { |(m, l), v| is_poly.call(m, l) ? v : 0.0 }
  hot_poly_share = user_pct.zero? ? 0.0 : 100.0 * hot_poly_pct / user_pct

  if json
    out = { file: src, runtime_pct: runtime_pct.round(1), gc_pct: gc_pct.round(1),
            runs: gmons.size, overlay: overlay,
            hot_poly_pct_of_user: hot_poly_share.round(1),
            methods: methods.map { |m, p| { method: m, self_pct: p.round(1) } },
            lines: ranked.map { |(m, l), p| { method: m, line: l, self_pct: p.round(1),
              source: src_lines[l-1]&.strip, slow_path: is_poly.call(m, l) } } }
    puts JSON.generate(out); next
  end

  gran = overlay == :types ? "per-line via --emit-types" : "per-method via --emit-rbs (no --emit-types; coarser)"
  puts "spinel-perf: #{src}   (gprof -l, #line + -pg -O2, #{gmons.size} runs summed)"
  printf "  self-time split:  %.0f%% user · %.0f%% GC · %.0f%% other-runtime/inlined\n", lines.values.sum, gc_pct, runtime_pct
  if gc_pct >= 15.0
    puts "    ⓘ GC self-time is high — a ceiling that's flat across workloads (cf. Q3,"
    puts "      spinel-dev#5) reads as periodic collector pause, not user-code cost."
  end
  printf "  hot ∧ poly: %.0f%% of user self-time is on the boxed slow path  (⚠ overlay: %s)\n\n", hot_poly_share, gran
  puts "  hot methods (self-time, stable):"
  methods.each { |m, pct| printf "  %5.1f%%  %s%s\n", pct, (lines.any? { |(mm, l), _| mm == m && is_poly.call(mm, l) } ? "⚠ " : "  "), m }
  puts "\n  hot lines (sample-limited — gprof 10ms; heavier workload = finer):"
  ranked.each do |(m, l), pct|
    printf "  %5.1f%%  %s%-22s %-9s %s\n", pct, (is_poly.call(m, l) ? "⚠ " : "  "), m, "#{base}:#{l}", (src_lines[l-1]&.strip || "")[0, 42]
  end
  hot_slow = ranked.select { |(m, l), _| is_poly.call(m, l) }
  if hot_slow.any?
    puts "\n  → hottest lines on the boxed slow path: " +
         hot_slow.first(3).map { |(m, l), _| "#{m} @ #{base}:#{l}" }.join(", ")
    puts "    (un-inferred dynamism, where it's hot — type those to speed up.)"
  end
  puts "\n  (spike — gprof's per-line is coarse on short runs; a permitted `perf` would\n   sharpen it. ⚠ is #{overlay == :types ? "per-line (--emit-types)" : "per-method (--emit-rbs fallback)"}.)"
end
