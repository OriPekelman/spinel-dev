#!/usr/bin/env ruby
# frozen_string_literal: true
#
# spinel-migrate — can a project move to a new Spinel, and if not, what's blocking?
#
# Compiles a project's build targets with a candidate compiler (--to) and,
# optionally, the current pin (--from), then reports a go/no-go diff: which
# targets newly fail, each attributed to a Ruby source site. This is the manual
# probe done by hand at every big matz/master bump — "build each target on the
# old pin and the new one, diff the outcomes" — codified. See docs/09.
#
# Usage:
#   spinel-migrate.rb [--json] --to <spinel_dir> [--from <spinel_dir>] \
#                     [--rbs DIR] [--root DIR] <target.rb> [target2.rb ...]
#
#   --to    candidate compiler checkout (the one you want to move to)
#   --from  current/baseline compiler (optional; enables the regression diff)
#   --rbs   passed through to spinel (advisory signatures), e.g. a project sig/ dir
#   --root  chdir here before compiling (so require_relative + FFI marker paths
#           resolve as they do in the project's own build); default: cwd
#
# Exit 0 if every target compiles on --to; 1 if any target fails on --to; 2 on
# a usage / setup error.

require "json"
require "tmpdir"
require "open3"

HERE = File.expand_path(File.dirname(__FILE__))
PROBE = File.join(HERE, "..", "probe", "spinel-probe.rb")

def die(msg) = abort("spinel-migrate: #{msg}")

json = !!ARGV.delete("--json")
opt = ->(name) { (i = ARGV.index(name)) ? ARGV.delete_at(i + 1).tap { ARGV.delete_at(i) } : nil }
to_dir   = opt.("--to")
from_dir = opt.("--from")
rbs_dir  = opt.("--rbs")
root     = opt.("--root")
targets  = ARGV.dup

die "missing --to <spinel_dir>"        unless to_dir
die "no targets given"                 if targets.empty?
die "--to: no spinel at #{to_dir}/spinel" unless File.executable?(File.join(to_dir, "spinel"))
die "--from: no spinel at #{from_dir}/spinel" if from_dir && !File.executable?(File.join(from_dir, "spinel"))
targets.each { |t| die "no such target: #{t}" unless File.file?(File.join(root || ".", t)) }

# Manifest of each compiler (built on spinel-probe), for the report header and
# to record what we're actually comparing.
def probe(dir)
  out, st = Open3.capture2({ "SPINEL_DIR" => dir }, "ruby", PROBE, "--json")
  st.success? ? (JSON.parse(out) rescue nil) : nil
end

# First attributable blocker from a failed compile's combined output. Prefer a
# cc error mapped (via #line) to a .rb source site; fall back to spinel's own
# codegen-refusal diagnostic.
def first_blocker(out)
  out.each_line do |l|
    if (m = l.match(%r{([^\s:]+\.rb):(\d+)(?::\d+)?:\s*(?:fatal\s+)?error:\s*(.+)}))
      return { site: "#{File.basename(m[1])}:#{m[2]}", message: m[3].strip[0, 140] }
    end
  end
  out.each_line do |l|
    if (m = l.match(/^spinel: (.*(?:unsupported|C compilation failed|error).*)/))
      return { site: nil, message: m[1].strip[0, 140] }
    end
  end
  { site: nil, message: (out.lines.grep(/error|spinel:/i).first&.strip&.slice(0, 140) || "unknown failure") }
end

def compile(spinel_dir, target, rbs, root, w, tag)
  bin = File.join(w, "bin_#{tag}")
  args = [File.join(spinel_dir, "spinel")]
  args += ["--rbs", rbs] if rbs           # mode flag before the source (shell-driver safe)
  args += [target, "-o", bin]
  out, st = Open3.capture2e(*args, chdir: (root || "."))
  ok = st.success? && File.size?(bin)
  { compiled: !!ok, size: (ok ? File.size(bin) : 0), blocker: (ok ? nil : first_blocker(out)) }
end

to_manifest   = probe(to_dir)
from_manifest = from_dir ? probe(from_dir) : nil

rows = []
Dir.mktmpdir("spinel_migrate") do |w|
  targets.each_with_index do |t, i|
    row = { target: t }
    row[:from] = compile(from_dir, t, rbs_dir, root, w, "from_#{i}") if from_dir
    row[:to]   = compile(to_dir,   t, rbs_dir, root, w, "to_#{i}")
    # classification (only meaningful with --from)
    if from_dir
      fc = row[:from][:compiled]; tc = row[:to][:compiled]
      row[:status] = if fc && tc then "ok"
                     elsif !fc && tc then "fixed"
                     elsif fc && !tc then "REGRESSED"
                     else "still-broken"
                     end
    else
      row[:status] = row[:to][:compiled] ? "ok" : "blocked"
    end
    rows << row
  end
end

blockers_on_to = rows.reject { |r| r[:to][:compiled] }
verdict = blockers_on_to.empty? ? "ready" : "blocked-on-#{blockers_on_to.size}"

if json
  puts JSON.generate(verdict: verdict, to: to_manifest, from: from_manifest, targets: rows)
  exit(blockers_on_to.empty? ? 0 : 1)
end

# ---- human report ---------------------------------------------------------
label = ->(m, dir) { m ? "#{m['driver']}/#{m['layout']} #{m['error_model']}" : dir }
puts "spinel-migrate"
puts "  to:   #{to_dir}   [#{label.(to_manifest, to_dir)}]"
puts "  from: #{from_dir}   [#{label.(from_manifest, from_dir)}]" if from_dir
puts
fmt_size = ->(b) { b.zero? ? "—" : "#{(b / 1024.0).round}K" }
rows.each do |r|
  mark = { "ok" => "✓", "fixed" => "✓", "REGRESSED" => "✗", "still-broken" => "✗", "blocked" => "✗" }[r[:status]]
  printf "  %s %-32s %s\n", mark, r[:target], r[:status]
  if from_dir
    printf "      from: %s%s\n", (r[:from][:compiled] ? "ok (#{fmt_size.(r[:from][:size])})" : "FAIL"),
           (r[:from][:blocker] ? "  #{[r[:from][:blocker][:site], r[:from][:blocker][:message]].compact.join('  ')}" : "")
  end
  printf "      to:   %s%s\n", (r[:to][:compiled] ? "ok (#{fmt_size.(r[:to][:size])})" : "FAIL"),
         (r[:to][:blocker] ? "  #{[r[:to][:blocker][:site], r[:to][:blocker][:message]].compact.join('  ')}" : "")
end
puts
case verdict
when "ready"
  puts "  verdict  READY — every target compiles on --to."
else
  puts "  verdict  BLOCKED — #{blockers_on_to.size} target(s) fail on --to:"
  blockers_on_to.each do |r|
    b = r[:to][:blocker]
    puts "             - #{r[:target]}: #{[b[:site], b[:message]].compact.join('  ')}"
  end
  if from_dir && (reg = rows.select { |r| r[:status] == "REGRESSED" }).any?
    puts "           (#{reg.size} are REGRESSIONS — compiled on --from, now fail on --to.)"
  end
end

exit(blockers_on_to.empty? ? 0 : 1)
