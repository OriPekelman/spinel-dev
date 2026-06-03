#!/usr/bin/env ruby
# frozen_string_literal: true
#
# SPIKE — "why is my Spinel app slow / what's slow?"
#
# Compiles the program with gprof instrumentation (-pg -g -O2), runs it, and turns
# gprof's flat profile of `sp_<method>` C functions back into a flat profile of
# *Ruby methods* — then overlays the inference degrade scan, so each hot method is
# tagged whether it sat on the boxed poly slow path. "What's slow" (the hot
# methods) and "why" (the ones that didn't type) land together.
#
# Uses gprof (no kernel perf perms; `perf` is locked down at
# perf_event_paranoid=4 here). Caveat: -O2 inlines small methods into callers, so
# very small hot methods are attributed upward.
#
# Usage: SPINEL_DIR=~/sites/spinel ruby spinel-perf.rb <program.rb> [-- args...]

require "tmpdir"

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

# Mirror sp_bt_symbol: sp_<Class>_<method> -> Class#method / Class.method / bare.
def demangle(sym)
  return nil unless sym&.start_with?("sp_")
  name = sym[3..]
  return :runtime if name =~ RUNTIME_PFX
  mstart = nil
  name.chars.each_with_index do |c, i|
    if (i.zero? || name[i - 1] == "_") && c =~ /[a-z]/ then mstart = i; break end
  end
  return name unless mstart
  return (name.start_with?("cls_") ? name[4..] : name) if mstart.zero?
  meth = name[mstart..]; sep = "#"
  if meth.start_with?("cls_") then meth = meth[4..]; sep = "." end
  "#{name[0...(mstart - 1)].gsub('_', '::')}#{sep}#{meth}"
end

src = ARGV.shift or abort "usage: spinel-perf.rb <program.rb> [-- args...]"
ARGV.shift if ARGV.first == "--"
prog_args = ARGV

Dir.mktmpdir("spinel_perf") do |w|
  cfile = File.join(w, "out.c")
  unless system(SPINEL, src, "-c", "-o", cfile, out: File::NULL, err: File::NULL) && File.size?(cfile)
    abort "spinel-perf: codegen failed (does it compile? try `spinel doctor`)"
  end
  c = File.read(cfile)
  links  = c.scan(%r{^/\* SPINEL_LINK: (.*) \*/$}).flatten.join(" ")
  cflags = c.scan(%r{^/\* SPINEL_CFLAGS: (.*) \*/$}).flatten.join(" ")
  bin = File.join(w, "prof")
  cc = "#{CC} -pg -g -O2 -Wno-all -I#{SPINEL_DIR}/lib -I#{SPINEL_DIR}/lib/regexp #{cflags} " \
       "#{cfile} #{SPINEL_DIR}/lib/libspinel_rt.a -lm #{OVF} #{links} -o #{bin}"
  unless system("#{cc} 2>#{w}/cc.err")
    abort "spinel-perf: C build failed (FFI placeholders? see below)\n" +
          File.read("#{w}/cc.err").lines.grep(/error|@[A-Z_]+@/).first(4).join
  end

  Dir.chdir(w) { system(bin, *prog_args, out: File::NULL, err: File::NULL) }
  gmon = File.join(w, "gmon.out")
  abort "spinel-perf: no gmon.out — workload too short to sample; run a heavier input." unless File.file?(gmon)

  # Degrade set: Ruby methods whose --emit-rbs signature widened to untyped.
  rbs = File.join(w, "x.rbs")
  system(SPINEL, src, "--emit-rbs", "-o", rbs, out: File::NULL, err: File::NULL)
  degraded = {}
  if File.size?(rbs)
    File.foreach(rbs) do |l|
      next unless l.include?("untyped")
      mn = l[/^\s*def\s+([A-Za-z_]\w*)\s*:/, 1]   # flat-mangled `def Tep_Url_cls_x:`
      r = demangle("sp_#{mn}") if mn
      degraded[r] = true if r.is_a?(String)
    end
  end

  hot = Hash.new(0.0)
  `gprof -p -b #{bin} #{gmon} 2>/dev/null`.each_line do |ln|
    next unless ln =~ /^\s*(\d+\.\d+)\s+[\d.]+\s+[\d.]+\s+(?:[\d.]+\s+[\d.]+\s+[\d.]+\s+)?(\w+)\s*$/
    r = demangle($2)
    hot[r] += $1.to_f if r.is_a?(String)
  end

  ranked = hot.sort_by { |_, v| -v }.first(15)
  user_total = hot.values.sum
  puts "spinel-perf: #{src}   (gprof, -pg -O2; self-time by Ruby method)"
  puts "  ~%.0f%% of sampled self-time is in named user methods (rest: runtime/GC/inlined)\n\n" % user_total
  printf "  %6s  %-38s %s\n", "self%", "method", "inference"
  ranked.each do |r, pct|
    printf "  %5.1f%%  %-38s%s\n", pct, r, (degraded[r] ? "  [SLOW: untyped / poly slow path]" : "")
  end
  if (slow = ranked.select { |r, _| degraded[r] }).any?
    puts "\n  → hot + on the slow path: #{slow.map(&:first).join(', ')} — start here."
  end
  puts "\n  (spike — per-method via gprof + --emit-rbs overlay. Per-line would read the\n   #line map directly; perf is locked down here, gprof is the portable path.)"
end
