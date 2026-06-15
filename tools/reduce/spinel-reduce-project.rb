#!/usr/bin/env ruby
# frozen_string_literal: true
#
# spinel-reduce-project — reduce a MULTI-FILE project to a minimal repro of a
# surface-dependent compile failure (RFC docs/09 tool #4).
#
# The recurring "f7ae245 signature": an isolated probe compiles, but the full
# compilation surface miscompiles (a poly/array element type degrades only once
# enough of the program is in scope). Single-file ddmin can't touch it — the
# trigger lives in the cross-file whole-program inference — so these get filed
# un-reduced (spinel-dev#24's Mat blocker; the serve `backoff`/multi-arg gaps).
#
# This reduces across the real require_relative graph, using the PROJECT'S OWN
# BUILD as the oracle (`spinel [--rbs DIR] <entry> -o bin`, run in --root) so
# --rbs, FFI link/cflags, and require resolution all behave as they do in the
# real build — which `doctor -c` on a flattened single file cannot reproduce.
# Two passes: drop whole files from the graph, then drop top-level defs/classes
# from the survivors, keeping only what still reproduces the target error.
#
# Usage:
#   SPINEL_DIR=<dir>  ruby spinel-reduce-project.rb \
#       [--rbs DIR] [--root DIR] [--target SUBSTR] [-o OUTDIR] <entry.rb>
#
#   --target  error substring that defines "still reproduces" (default: the
#             message of the first blocker on the unmodified build)
#   --root    chdir here to compile (so require_relative + FFI paths resolve);
#             default: the entry file's directory's git root, else cwd
#   -o OUTDIR copy the reduced tree here (default: just report the survivors)
#
# SAFETY: reduces the reachable .rb files IN PLACE, restoring every one on exit
# (incl. Ctrl-C). They are expected to be git-tracked — `git checkout` is the
# backstop if the process is hard-killed.

require "tmpdir"
require "open3"
require "digest"
require "fileutils"

SPINEL_DIR = ENV["SPINEL_DIR"] || File.expand_path("~/sites/spinel")
SPINEL = ENV["SPINEL_BIN"] || File.join(SPINEL_DIR, "spinel")
abort "spinel-reduce-project: #{SPINEL} not found" unless File.executable?(SPINEL)

# ---- args ----
opt = { rbs: nil, root: nil, target: nil, out: nil }
argv = ARGV.dup
until argv.empty?
  a = argv.shift
  case a
  when "--rbs"    then opt[:rbs] = argv.shift
  when "--root"   then opt[:root] = argv.shift
  when "--target" then opt[:target] = argv.shift
  when "-o"       then opt[:out] = argv.shift
  when /\A--/     then abort "unknown flag #{a}"
  else opt[:entry] = a
  end
end
entry = opt[:entry] or abort "usage: spinel-reduce-project.rb [--rbs DIR] [--root DIR] [--target SUBSTR] [-o OUTDIR] <entry.rb>"
abort "no such file: #{entry}" unless File.file?(entry)

def git_root(dir)
  out, _err, st = Open3.capture3("git", "-C", dir, "rev-parse", "--show-toplevel")
  st.success? ? out.strip : nil
end
ROOT = File.expand_path(opt[:root] || git_root(File.dirname(File.expand_path(entry))) || Dir.pwd)
ENTRY = File.expand_path(entry)

# ---- require_relative graph discovery (depth-first, deduped) ----
REQ_REL = /\A\s*require_relative\s+(["'])(.+?)\1/
def resolve_req(arg, from_dir)
  base = File.expand_path(arg, from_dir)
  [base, "#{base}.rb"].find { |c| File.file?(c) }
end
def reachable(entry)
  seen = {}
  order = []
  stack = [File.expand_path(entry)]
  until stack.empty?
    p = stack.shift
    rp = (File.realpath(p) rescue p)
    next if seen[rp]
    seen[rp] = true
    order << p
    File.foreach(p) do |line|
      if (m = line.match(REQ_REL)) && (t = resolve_req(m[2], File.dirname(p)))
        stack << t
      end
    end
  end
  order
end

FILES = reachable(ENTRY)                      # abs paths, entry first
ORIG = FILES.to_h { |f| [f, File.read(f)] }   # snapshot for restore
content = ORIG.dup                            # current candidate (abs path -> source)

restore = -> { ORIG.each { |f, s| File.write(f, s) rescue nil } }
at_exit { restore.call }
%w[INT TERM].each { |sig| trap(sig) { restore.call; exit 130 } }

# ---- oracle: write the candidate, run the real build, match the target ----
$calls = 0
$cache = {}
def build_output
  Dir.mktmpdir("srp") do |w|
    bin = File.join(w, "b")
    args = [SPINEL]
    args += ["--rbs", OPT_RBS] if OPT_RBS
    args += [ENTRY, "-o", bin]
    out, _st = Open3.capture2e(*args, chdir: ROOT)
    out
  end
end
OPT_RBS = opt[:rbs] && File.expand_path(opt[:rbs])

# `target` is a Regexp so the failure stays pinned to its FILE + MESSAGE while
# the line number is free to shift as code is removed (a plain substring drifts:
# removing the offending class makes the same message reappear at a different
# site, and a file:line target breaks the moment a line is dropped).
def reproduces?(content, target_re)
  key = Digest::SHA1.hexdigest(content.keys.sort.map { |k| "#{k}\0#{content[k]}" }.join("\0"))
  return $cache[key] if $cache.key?(key)
  content.each { |f, s| File.write(f, s) }
  $calls += 1
  out = build_output
  $cache[key] = !!(out =~ target_re)
end

# Every removable def/class/module block, at ANY indentation — matched by
# indentation (the `end` at the same column as the keyword). Conventionally
# indented Ruby (which the targets are). Returns ranges largest-first, so a
# whole class is tried before its individual methods (more churn per build).
def removable_ranges(lines)
  ranges = []
  lines.each_with_index do |ln, i|
    next unless (m = ln.match(/\A(\s*)(def|class|module)\b/))
    indent = m[1]
    j = i + 1
    j += 1 while j < lines.size && lines[j] !~ /\A#{indent}end\b/
    ranges << [i, j] if j < lines.size
  end
  ranges.sort_by { |st, en| -(en - st) }
end

# ---- pick target ----
# Build a line-agnostic regex for the first blocker: pin the FILE basename and
# the error message, leave the line/col free (`\d+`). This keeps the reduction
# faithful to the original site as code shifts around it.
def first_blocker_regex(out)
  out.each_line do |l|
    if (m = l.match(%r{([^\s:/]+\.rb):\d+(?::\d+)?:\s*(?:fatal\s+)?error:\s*(.+)}))
      return Regexp.new("#{Regexp.escape(m[1])}:\\d+(?::\\d+)?:.*error:.*#{Regexp.escape(m[2].strip)}")
    end
  end
  out.each_line do |l|
    if l =~ /^spinel: .*(unsupported|error|failed)/
      # Wildcard digit runs (node ids, type ids, argc) — they shift as code is
      # removed, so pinning them would make even a correct reduction miss.
      body = Regexp.escape(l.strip.sub(/^spinel:\s*/, "")).gsub(/\d+/, '\\\\d+')
      return Regexp.new("^spinel: #{body}")
    end
  end
  nil
end

restore.call                                  # ensure pristine for the baseline
base_out = build_output
# A user --target is treated as a regex pattern (a plain substring is a valid one).
target = opt[:target] ? Regexp.new(opt[:target]) : first_blocker_regex(base_out)
abort "spinel-reduce-project: the build is clean (nothing to reduce). Pass --target." if target.nil?
$stderr.puts "spinel-reduce-project: entry=#{File.basename(ENTRY)}  root=#{ROOT}"
$stderr.puts "  reachable .rb files: #{FILES.size}"
$stderr.puts "  target: /#{target.source}/"
abort "spinel-reduce-project: target not reproduced on the unmodified build — refine --target." \
  unless reproduces?(content, target)

# ---- pass 1: drop whole files (empty their bodies) ----
# ddmin over the non-entry reachable files: a file we can blank while the target
# survives wasn't load-bearing for the bug. Entry stays (it's the build root).
def file_pass(content, target, droppable)
  n = 2
  files = droppable.dup
  while files.size >= 1
    chunk = [(files.size.to_f / n).ceil, 1].max
    removed = false
    start = 0
    while start < files.size
      victim = files[start, chunk]
      trial = content.dup
      victim.each { |f| trial[f] = "# spinel-reduce-project: emptied\n" }
      if reproduces?(trial, target)
        content = trial
        files -= victim
        removed = true
        $stderr.printf "  dropped %d file(s) -> %d live  (%d builds)\n",
                       victim.size, content.count { |_, s| s !~ /\A# spinel-reduce-project: emptied/ }, $calls
        break
      end
      start += chunk
    end
    next if removed
    break if n >= files.size
    n = [n * 2, files.size].min
  end
  content
end

droppable = FILES - [ENTRY]
content = file_pass(content, target, droppable)
live = FILES.select { |f| content[f] !~ /\A# spinel-reduce-project: emptied/ }
$stderr.puts "  -- pass 1 done: #{live.size}/#{FILES.size} files still load-bearing --"

# ---- pass 2: drop top-level blocks from each surviving file ----
live.each do |f|
  changed = true
  while changed
    changed = false
    lines = content[f].lines
    removable_ranges(lines).each do |st, en|
      cand = lines[0...st] + (lines[(en + 1)..] || [])
      next if cand.empty?
      next unless (system("ruby", "-c", "-e", cand.join, out: File::NULL, err: File::NULL) rescue false)
      trial = content.dup
      trial[f] = cand.join
      if reproduces?(trial, target)
        content = trial
        changed = true
        $stderr.printf "  %s: dropped block (lines %d-%d) -> %d lines  (%d builds)\n",
                       File.basename(f), st + 1, en + 1, cand.size, $calls
        break
      end
    end
  end
end

# ---- pass 3: line-level cleanup within survivors ----
# Block removal can't touch module-level statements or non-def/class blocks
# (constants, `if`/anchor blocks). A greedy single-line sweep (ruby -c gated)
# removes those too, driving toward a true minimal surface.
live.each do |f|
  changed = true
  while changed
    changed = false
    lines = content[f].lines
    i = 0
    while i < lines.size
      cand = lines[0...i] + (lines[(i + 1)..] || [])
      if !cand.empty? && (system("ruby", "-c", "-e", cand.join, out: File::NULL, err: File::NULL) rescue false) && reproduces?(content.merge(f => cand.join), target)
        content = content.merge(f => cand.join)
        lines = cand
        changed = true
      else
        i += 1
      end
    end
  end
end

# ---- report ----
restore.call
live = FILES.select { |f| content[f] !~ /\A# spinel-reduce-project: emptied/ }
$stderr.puts "\n  REDUCED: #{FILES.size} -> #{live.size} files, #{$calls} builds. Target still reproduces:"
$stderr.puts "    #{target.inspect}"
live.each do |f|
  rel = f.sub(/\A#{Regexp.escape(ROOT)}\//, "")
  $stderr.puts "    - #{rel}  (#{content[f].lines.size} lines#{f == ENTRY ? ', entry' : ''})"
end

if opt[:out]
  FileUtils.mkdir_p(opt[:out])
  live.each do |f|
    rel = f.sub(/\A#{Regexp.escape(ROOT)}\//, "")
    dst = File.join(opt[:out], rel)
    FileUtils.mkdir_p(File.dirname(dst))
    File.write(dst, content[f])
  end
  $stderr.puts "\n  wrote reduced tree to #{opt[:out]}/ (#{live.size} files)"
else
  $stderr.puts "\n  (pass -o OUTDIR to write the reduced tree; the survivors above are the minimal surface.)"
end
