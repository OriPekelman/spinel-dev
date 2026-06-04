#!/usr/bin/env ruby
# frozen_string_literal: true
#
# SPIKE — Spinel-aware flamegraph (spinel-dev#5/#7).
#
# Turns a Spinel binary's gprof call graph into a flamegraph whose frames are
# *Ruby methods* (not C symbols), with the runtime layered by cost class:
#   - GC/alloc frames (the ~55% ceiling on the Rails corpus) in red,
#   - other runtime in grey,
#   - user Ruby methods (`Class#method`) in blue,
#   - user frames on the boxed poly slow path in orange (hot ∧ poly, visual).
#
# Why gprof: `perf` is locked down here (perf_event_paranoid=4), so we use the
# `-pg` call graph. It's exact on call *counts* (instrumented) and sampled on
# time; the fold below apportions each function's self-time up its caller paths
# (the stackcollapse-gprof algorithm), demangling `sp_<Class>_<method>` the same
# way the native backtrace does.
#
# Output: folded stacks (the universal flamegraph input — pipe to any renderer)
# and a self-contained SVG (no flamegraph.pl needed).
#
# Usage:
#   # from a program (compiles -pg, runs it, profiles):
#   SPINEL_DIR=~/sites/spinel ruby spinel-flamegraph.rb <program.rb> [-- args] [-o out.svg]
#   # or from an existing gprof profile (e.g. a server you drove separately):
#   ruby spinel-flamegraph.rb --gmon <binary> <gmon.out...> [-o out.svg]

require "tmpdir"

SPINEL_DIR = ENV["SPINEL_DIR"] || File.expand_path("~/sites/spinel")
SPINEL = File.join(SPINEL_DIR, "spinel")
CC = ENV["CC"] || "cc"

RUNTIME_PFX = /\A(int_|str_|float_|sym_|bigint|sprintf|raise|exc_|range|utf8|oom|bt_|
  backtrace|caller|StrArray|IntArray|FloatArray|PtrArray|PolyArray|Str|Int|Float|Hash|Range|
  Complex|Rational|Sym|alloc|free|to_s|dup|new|pack|unpack|regex|re_|idiv|imod|gcd|fdiv|ipow|
  json|String|Array|fiber|main\b)/x
GC_FRAME = /\Asp_gc_\w|_gc_scan\b|\Asp_gc_alloc\b/

def classify(sym) # -> [:gc|:runtime|:user, ruby_label]
  return [:runtime, sym] unless sym&.start_with?("sp_")
  return [:gc, sym[3..]] if sym =~ GC_FRAME
  name = sym[3..]
  return [:runtime, name] if name =~ RUNTIME_PFX
  # sp_<Class>_<method> -> Class#method / Class.method
  mstart = nil
  name.chars.each_with_index { |c, i| (mstart = i; break) if (i.zero? || name[i-1] == "_") && c =~ /[a-z]/ }
  return [:runtime, name] unless mstart
  if mstart.zero?
    return [:user, name.start_with?("cls_") ? name[4..] : name]
  end
  meth = name[mstart..]; sep = "#"
  meth = (sep = "."; meth[4..]) if meth.start_with?("cls_")
  [:user, "#{name[0...(mstart-1)].gsub('_', '::')}#{sep}#{meth}"]
end

# ---- parse args ----
gmon_mode = ARGV.delete("--gmon")
oi = ARGV.index("-o"); out_svg = oi ? ARGV.delete_at(oi + 1) : nil
ARGV.delete("-o") if oi
poly_file = nil # path to --emit-types JSON for the orange slow-path overlay (optional)

def build_graph(bin, gmons)
  # Self-time per function (flat) + caller fractions (call graph).
  self_pct = Hash.new(0.0)
  `gprof -p -b #{bin} #{gmons.join(' ')} 2>/dev/null`.each_line do |l|
    next unless l =~ /^\s*(\d+\.\d+)\s+[\d.]+\s+[\d.]+\s+.*?\b(\w+)\s*$/
    self_pct[$2] += $1.to_f
  end
  # Call graph: parents of each function with call fractions.
  parents = Hash.new { |h, k| h[k] = [] } # fn -> [[parent, fraction], ...]
  names = {}                              # index -> fn name
  cur = nil; pre = []
  `gprof -q -b #{bin} #{gmons.join(' ')} 2>/dev/null`.each_line do |l|
    if l =~ /^\[\d+\]\s+[\d.]+\s+[\d.]+\s+[\d.]+\s+(?:[\d+]+\s+)?(\w+)\s*\[(\d+)\]/
      cur = $1; names[$2] = $1
      # lines collected in `pre` are this fn's callers: "self children calls/total parent [idx]"
      tot = pre.sum { |c| c[:calls] }
      pre.each { |c| parents[cur] << [c[:name], tot > 0 ? c[:calls].to_f / tot : 0.0] } if tot > 0
      pre = []
    elsif l =~ /^-{5,}/
      pre = []
    elsif cur.nil? && l =~ %r{\b(\d+)/(\d+)\s+(\w+)\s*\[\d+\]}
      pre << { calls: $1.to_i, name: $3 } # caller line (before the [idx] entry)
    elsif l =~ %r{^\s+[\d.]+\s+[\d.]+\s+(\d+)/(\d+)\s+(\w+)\s*\[\d+\]}
      # could be caller (above entry) or callee (below). Heuristic: collect as
      # potential caller for the NEXT entry; reset on separator handles callees.
      pre << { calls: $1.to_i, name: $3 }
    end
  end
  [self_pct, parents]
end

# Fold: for each fn, distribute its self-time up all root-rooted caller paths.
def fold(self_pct, parents)
  folded = Hash.new(0.0)
  self_pct.each do |fn, slf|
    next if slf <= 0.0
    # enumerate root paths via DFS up the parents, cycle-guarded, depth-capped.
    stacks = [] # [[frames...], weight]
    walk = lambda do |node, path, frac, depth|
      ps = parents[node]
      if ps.nil? || ps.empty? || depth > 64 || path.include?(node)
        stacks << [[node] + path, frac]
        return
      end
      ps.each { |(par, f)| walk.call(par, [node] + path, frac * (f <= 0 ? 1.0 : f), depth + 1) }
    end
    walk.call(fn, [], 1.0, 0)
    stacks.each { |frames, w| folded[frames] += slf * w }
  end
  folded
end

if gmon_mode
  bin = ARGV.shift or abort "usage: spinel-flamegraph.rb --gmon <binary> <gmon...>"
  gmons = ARGV.dup
  abort "no gmon files" if gmons.empty?
  self_pct, parents = build_graph(bin, gmons)
else
  src = ARGV.shift or abort "usage: spinel-flamegraph.rb <program.rb> [-- args]"
  ARGV.shift if ARGV.first == "--"
  prog_args = ARGV
  abort "no spinel at #{SPINEL}" unless File.executable?(SPINEL)
  self_pct = nil
  Dir.mktmpdir("spinel_flame") do |w|
    cfile = File.join(w, "o.c")
    system(SPINEL, "-g", src, "-c", "-o", cfile, out: File::NULL, err: File::NULL) or abort "codegen failed"
    c = File.read(cfile)
    links = c.scan(%r{^/\* SPINEL_LINK: (.*) \*/$}).flatten.join(" ")
    cflags = c.scan(%r{^/\* SPINEL_CFLAGS: (.*) \*/$}).flatten.join(" ")
    bin = File.join(w, "prof")
    cc = "#{CC} -pg -g -O2 -Wno-all -I#{SPINEL_DIR}/lib -I#{SPINEL_DIR}/lib/regexp #{cflags} #{cfile} #{SPINEL_DIR}/lib/libspinel_rt.a -lm #{links} -o #{bin}"
    system("#{cc} 2>/dev/null") or abort "cc failed"
    runs = (ENV["SPINEL_PERF_RUNS"] || "3").to_i
    gmons = []
    runs.times do |i|
      Dir.chdir(w) { system(bin, *prog_args, out: File::NULL, err: File::NULL) }
      g = File.join(w, "gmon.out"); break unless File.file?(g)
      dst = File.join(w, "gmon.#{i}"); File.rename(g, dst); gmons << dst
    end
    abort "no gmon (workload too short?)" if gmons.empty?
    self_pct, parents = build_graph(bin, gmons)
    @captured = fold(self_pct, parents)
  end
end
folded = defined?(@captured) && @captured ? @captured : fold(self_pct, parents)

# Demangle frames + collapse runtime detail. Each folded stack becomes a
# Ruby-labelled stack; tag the leaf's class for coloring.
out_folded = Hash.new(0.0)
leaf_class = {}
folded.each do |frames, w|
  labels = frames.map do |f|
    kind, lab = classify(f)
    next nil if lab.nil? || lab.empty? || lab =~ /\A[\d.]+\z/ # drop gprof junk frames
    leaf_class[lab] = kind
    lab
  end.compact
  next if labels.empty?
  # collapse consecutive duplicate runtime labels to keep the graph readable
  compact = []
  labels.each { |l| compact << l unless compact.last == l }
  out_folded[compact.join(";")] += w
end

folded_path = out_svg ? out_svg.sub(/\.svg$/, "") + ".folded" : "spinel-flame.folded"
File.write(folded_path, out_folded.sort_by { |_, v| -v }.map { |k, v| "#{k} #{(v * 100).round}" }.join("\n") + "\n")

# ---- emit a self-contained SVG flamegraph ----
out_svg ||= "spinel-flame.svg"
WIDTH = 1200; FRAME_H = 16; FONT = 11; PAD = 10
total = out_folded.values.sum
total = 1.0 if total <= 0

# Build a tree from folded stacks for rectangle layout.
root = { name: "all", val: 0.0, children: {}, kind: :root }
out_folded.each do |stack, w|
  node = root; root[:val] += w
  stack.split(";").each do |frame|
    node = (node[:children][frame] ||= { name: frame, val: 0.0, children: {}, kind: nil })
    node[:val] += w
  end
end

COLORS = { gc: "#d62728", runtime: "#9e9e9e", user: "#1f77b4", poly: "#ff7f0e", root: "#555" }
rects = []
emit = lambda do |node, depth, x0|
  w_px = (node[:val] / total) * (WIDTH - 2 * PAD)
  kind = node[:kind] || leaf_class[node[:name]] || :runtime
  kind = :root if node[:name] == "all"
  rects << { x: x0, depth: depth, w: w_px, name: node[:name], kind: kind, pct: 100.0 * node[:val] / total }
  cx = x0
  node[:children].values.sort_by { |c| -c[:val] }.each do |c|
    emit.call(c, depth + 1, cx)
    cx += (c[:val] / total) * (WIDTH - 2 * PAD)
  end
end
emit.call(root, 0, PAD)
max_depth = rects.map { |r| r[:depth] }.max + 1
height = max_depth * FRAME_H + 2 * PAD + 20

svg = +%(<svg xmlns="http://www.w3.org/2000/svg" width="#{WIDTH}" height="#{height}" font-family="Verdana" font-size="#{FONT}">\n)
svg << %(<rect width="#{WIDTH}" height="#{height}" fill="#f8f8f8"/>\n)
svg << %(<text x="#{PAD}" y="14" font-size="13" font-weight="bold">Spinel flamegraph — GC/alloc=red, runtime=grey, user Ruby (Class#method)=blue</text>\n)
rects.each do |r|
  next if r[:w] < 0.4
  y = height - PAD - (r[:depth] + 1) * FRAME_H
  fill = COLORS[r[:kind]] || COLORS[:runtime]
  label = r[:name].length * 7 < r[:w] ? r[:name] : ""
  title = "#{r[:name]} (#{r[:pct].round(1)}%)"
  svg << %(<g><title>#{title.gsub('&','&amp;').gsub('<','&lt;')}</title>)
  svg << %(<rect x="#{r[:x].round(1)}" y="#{y}" width="#{r[:w].round(1)}" height="#{FRAME_H - 1}" fill="#{fill}" stroke="#fff" stroke-width="0.3"/>)
  svg << %(<text x="#{(r[:x] + 2).round(1)}" y="#{y + FRAME_H - 4}" fill="#fff">#{label.gsub('&','&amp;').gsub('<','&lt;')}</text></g>\n) unless label.empty?
  svg << "</g>\n" if label.empty?
end
svg << "</svg>\n"
File.write(out_svg, svg)

# ---- summary to stdout ----
by_kind = Hash.new(0.0)
out_folded.each { |stack, w| by_kind[leaf_class[stack.split(";").last] || :runtime] += w }
puts "spinel-flamegraph: #{out_svg}  (folded: #{folded_path})"
puts "  leaf self-time by class:"
[:gc, :runtime, :user, :poly].each do |k|
  next unless by_kind[k] > 0
  printf "    %-8s %.1f%%\n", k, 100.0 * by_kind[k] / total
end
puts "  open the .svg in a browser; hover frames for Class#method (%); pipe the"
puts "  .folded to any flamegraph renderer if you prefer."
