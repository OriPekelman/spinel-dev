# CRuby side of the differential value-bisection harness.
#
# Runs a Ruby program under CRuby with a :line TracePoint and records, for
# every scalar local (Integer / Float / true / false), the ordered history
# of values it takes — but only when the value *changes*. That change-history
# is the unit the comparator diffs against the Spinel side, which makes the
# comparison robust to the two runtimes firing a different *number* of line
# events for the same control flow.
#
# Multi-file: each variable is keyed by "<basename>::<var>", so a `helper.rb`
# local and a `main.rb` local of the same name don't merge. Only files Spinel
# actually compiled are traced (passed in as a list); stdlib/gem frames are
# ignored. (Two methods in the *same* file sharing a local name still merge —
# a coarser-grained limitation, noted in the README.)
#
# Output (JSON): { "exit": <int>, "events": <int>,
#                  "histories": { "<file>::<var>": [[line, "tag:value"], ...] } }
#
# Value encoding is a typed string so the comparator never confuses Ruby's
# `false == 0` / `0.0 == 0` with a genuine match:
#   "i:<int>"   integer (arbitrary precision — Bignums survive as decimal text)
#   "f:<float>" float   (compared numerically, with tolerance, downstream)
#   "b:true|false"
# nil locals are skipped: Spinel declares every local up front (zero-init), so
# a "not yet assigned" nil on the CRuby side has no faithful counterpart.
#
# Usage: ruby cruby_trace.rb <program.rb> <out.json> <files-colon-list> [args...]

require "json"

target = File.expand_path(ARGV[0])
out_path = ARGV[1]
files_arg = ARGV[2] || ""
prog_argv = ARGV.length > 3 ? ARGV[3..] : []

# Set of canonical paths Spinel compiled (main + every require_relative'd
# file). Anything outside it — stdlib, gems — is not traced.
def canon(p)
  File.realpath(p)
rescue StandardError
  File.expand_path(p)
end

allowed = {}
allowed[target] = File.basename(target)
files_arg.split(":").each do |f|
  next if f.empty?
  allowed[canon(f)] = File.basename(f)
end

def scalarize(v)
  if v.is_a?(Integer)
    return "i:" + v.to_s
  end
  if v.is_a?(Float)
    return "f:" + v.to_s
  end
  if v == true || v == false
    return "b:" + v.to_s
  end
  nil
end

histories = Hash.new { |h, k| h[k] = [] }
last = {}
events = 0

tp = TracePoint.new(:line) do |t|
  base = allowed[canon(t.path)]
  next if base.nil?
  events += 1
  b = t.binding
  b.local_variables.each do |nm|
    sv = scalarize(b.local_variable_get(nm))
    next if sv.nil?
    key = base + "::" + nm.to_s
    if last[key] != sv
      last[key] = sv
 # [line, value, global-event-seq]; the seq lets the comparator rank
 # divergences by execution order (root cause before its consequences),
 # which line numbers across files can't express.
      histories[key].push([t.lineno, sv, events])
    end
  end
end

# Make the program see its own ARGV, not the harness's.
ARGV.replace(prog_argv)

exit_code = 0
begin
  tp.enable { load target }
rescue SystemExit => e
  exit_code = e.status
rescue Exception => e
  $stderr.puts "cruby_trace: program raised: #{e.class}: #{e.message}"
  exit_code = 70
ensure
  tp.disable
end

File.write(out_path, JSON.generate({
  "exit" => exit_code,
  "events" => events,
  "histories" => histories,
}))
