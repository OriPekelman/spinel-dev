# CRuby side of the differential value-bisection harness.
#
# Runs a Ruby program under CRuby with a :line TracePoint and records, for
# every scalar local (Integer / Float / true / false), the ordered history
# of values it takes — but only when the value *changes*. That change-history
# is the unit the comparator diffs against the Spinel side, which makes the
# comparison robust to the two runtimes firing a different *number* of line
# events for the same control flow.
#
# Output (JSON): { "exit": <int>, "events": <int>,
#                  "histories": { "<var>": [[line, "tag:value"], ...], ... } }
#
# Value encoding is a typed string so the comparator never confuses Ruby's
# `false == 0` / `0.0 == 0` with a genuine match:
#   "i:<int>"   integer (arbitrary precision — Bignums survive as decimal text)
#   "f:<float>" float   (compared numerically, with tolerance, downstream)
#   "b:true|false"
# nil locals are skipped: Spinel declares every local up front (zero-init), so
# a "not yet assigned" nil on the CRuby side has no faithful counterpart.
#
# Usage: ruby cruby_trace.rb <program.rb> <out.json> [program args...]

require "json"

target = File.expand_path(ARGV[0])
out_path = ARGV[1]
prog_argv = ARGV.length > 2 ? ARGV[2..] : []

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
  # Only the target file. require_relative'd files execute under their own
  # path; the Spinel side currently maps everything to the toplevel file
  # (single-file limitation), so restricting here keeps the two comparable.
  next unless File.expand_path(t.path) == target
  events += 1
  b = t.binding
  b.local_variables.each do |nm|
    sv = scalarize(b.local_variable_get(nm))
    next if sv.nil?
    key = nm.to_s
    if last[key] != sv
      last[key] = sv
      histories[key].push([t.lineno, sv])
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
  # A raise on the CRuby side is itself a signal; record it as a sentinel
  # "exit" so the comparator can note CRuby aborted.
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
