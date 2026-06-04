#!/usr/bin/env ruby
# frozen_string_literal: true
#
# spinel doctor-gate — a CI gate around `spinel doctor`.
#
# `spinel doctor` reports, per program, everything risky about compiling it with
# Spinel (unresolved calls that silently emit 0, methods widened to the boxed
# `untyped` slow path, and a behavior check vs CRuby). This wraps it for CI: run
# doctor over a set of *entrypoints*, compare the degrades against an *allowlist*
# of acknowledged ones, and exit non-zero on a **new** degrade (a regression) or
# any miscompile.
#
# Why an allowlist and not just "fail on any degrade": a degrade can be benign
# today because the path is dead (toy#32 — `embed_backward` widens to untyped but
# the gated training path runs through FFI/ggml, never the Ruby method). The
# behavioral gates can't protect a path they don't exercise; this catches the
# regression class where a refactor *re-activates* a latent degrade — all the
# byte-exact gates still green. So: allowlist the known-dead degrades, and the
# gate fires the moment a NEW one appears, or an allowlisted one starts to
# miscompile a path that's now live.
#
# Usage:
#   doctor-gate.rb [--config FILE] [--allow PAT]... [--github] [--json]
#                  [--spinel-dir DIR] [--no-cruby] [--no-bisect] [FILE.rb ...]
#
#   --config FILE   YAML config (default: ./.spinel-doctor-gate.yml if present)
#   --allow PAT     acknowledge a degrade whose text contains PAT (repeatable)
#   --github        emit GitHub Actions ::error::/::warning:: annotations
#   --json          machine-readable report on stdout
#   FILE.rb         entrypoints (added to any from --config)
#
# Exit: 0 clean / all degrades allowlisted; 1 on a new degrade or miscompile;
#       2 on a setup/tool error.
#
# Config (.spinel-doctor-gate.yml):
#   spinel_dir: ~/sites/spinel        # optional; env SPINEL_DIR wins
#   defaults: { no_cruby: true, no_bisect: false }
#   entrypoints:
#     - lib/toy/run/train.rb          # string = path, uses defaults
#     - { path: lib/toy/run/infer.rb, no_cruby: true }   # per-entry override
#   allow:                            # acknowledged dead-but-latent degrades
#     - embed_backward                # matched as a substring of the degrade text
#     - cross_entropy_grad

require "json"
require "yaml"
require "open3"

HERE   = File.expand_path(__dir__)
DOCTOR = File.join(HERE, "doctor.sh")
abort "doctor-gate: #{DOCTOR} not found" unless File.exist?(DOCTOR)

opts = { allow: [], files: [], github: false, json: false, no_cruby: nil, no_bisect: nil,
         config: nil, spinel_dir: nil }
argv = ARGV.dup
until argv.empty?
  a = argv.shift
  case a
  when "--config"     then opts[:config]     = argv.shift
  when "--allow"      then opts[:allow]      << argv.shift
  when "--github"     then opts[:github]     = true
  when "--json"       then opts[:json]       = true
  when "--spinel-dir" then opts[:spinel_dir] = argv.shift
  when "--no-cruby"   then opts[:no_cruby]   = true
  when "--no-bisect"  then opts[:no_bisect]  = true
  when "-h", "--help" then puts File.read(__FILE__)[/\A.*?^$/m]; exit 0
  when /\A--/         then abort "doctor-gate: unknown flag #{a}"
  else opts[:files] << a
  end
end

# Load config (explicit --config, else ./.spinel-doctor-gate.yml if present).
cfg_path = opts[:config] || (File.exist?(".spinel-doctor-gate.yml") ? ".spinel-doctor-gate.yml" : nil)
cfg = cfg_path ? (YAML.safe_load_file(cfg_path) || {}) : {}
abort "doctor-gate: config not found: #{cfg_path}" if opts[:config] && !File.exist?(opts[:config])

defaults = cfg["defaults"] || {}
allow    = (cfg["allow"] || []).map(&:to_s) + opts[:allow]

# Entrypoints: config entries (string or {path, ...overrides}) + CLI files.
entries = (cfg["entrypoints"] || []).map do |e|
  e.is_a?(Hash) ? e : { "path" => e.to_s }
end
opts[:files].each { |f| entries << { "path" => f } }
abort "doctor-gate: no entrypoints (config 'entrypoints:' or FILE.rb args)" if entries.empty?

spinel_dir = ENV["SPINEL_DIR"] || opts[:spinel_dir] || cfg["spinel_dir"] ||
             File.expand_path("~/sites/spinel")
spinel_dir = File.expand_path(spinel_dir)

# Run doctor --json on one entrypoint; return its parsed report (or an error stub).
def run_doctor(entry, defaults, opts, spinel_dir)
  path = entry["path"]
  return { "file" => path, "error" => "no such file" } unless File.file?(path)
  no_cruby  = [entry["no_cruby"],  opts[:no_cruby],  defaults["no_cruby"]].compact.first
  no_bisect = [entry["no_bisect"], opts[:no_bisect], defaults["no_bisect"]].compact.first
  cmd = ["/bin/sh", DOCTOR, "--json"]
  cmd << "--no-cruby"  if no_cruby
  cmd << "--no-bisect" if no_bisect
  cmd << path
  out, _err, st = Open3.capture3({ "SPINEL_DIR" => spinel_dir }, *cmd)
  return { "file" => path, "error" => "doctor failed to run (exit #{st.exitstatus})" } if out.strip.empty?
  JSON.parse(out)
rescue JSON::ParserError => e
  { "file" => path, "error" => "unparseable doctor output: #{e.message}" }
end

# A finding = one degrade signal, with a text we match the allowlist against.
def findings_for(rep)
  f = []
  # An ignored require is the prime suspect for an emit-0 cascade (#9) — surfaced
  # first, allowlistable (a benign stdlib like `'time'` can be acknowledged; a
  # wrong-path require then still fails CI).
  (rep.dig("compile", "ignored_requires") || []).each do |r|
    f << { kind: "ignored-require", text: r.to_s, hard: false }
  end
  (rep.dig("compile", "unresolved_calls") || []).each do |c|
    f << { kind: "unresolved", text: c.to_s, hard: false }
  end
  (rep.dig("inference", "degraded_methods") || []).each do |m|
    f << { kind: "degraded", text: m.to_s, hard: false }
  end
  # Inference↔codegen disagreements (the silent-miscompile fingerprint, #9) are
  # allowlistable like degrades — a confirmed-dead one can be acknowledged — but
  # surfaced as a distinct, more-severe kind, so a *new* one fails CI loudly.
  (rep["disagreements"] || []).each do |d|
    f << { kind: "disagreement", text: d.to_s, hard: false }
  end
  # A codegen build failure (#10) — the program doesn't compile. Never
  # allowlistable: a non-building program is never acceptable.
  cg = rep["codegen"]
  if cg
    f << { kind: "codegen", text: "codegen #{cg['error_class']} on #{cg['symbol']}: #{cg['message']}", hard: true }
  end
  b = rep["behavior"]
  verdict = b.is_a?(Hash) ? b["verdict"] : b
  if %w[diverge output-differ crash abort].include?(verdict)
    # A live miscompile — never allowlistable.
    f << { kind: "miscompile", text: "behavior: #{verdict}", hard: true }
  end
  f
end

allowed_by = Hash.new { |h, k| h[k] = [] } # allow-pattern -> [finding texts it matched]
results = entries.map do |entry|
  rep = run_doctor(entry, defaults, opts, spinel_dir)
  next { file: entry["path"], error: rep["error"] } if rep["error"]
  findings = findings_for(rep)
  findings.each do |fi|
    next if fi[:hard]
    hit = allow.find { |pat| fi[:text].include?(pat) }
    if hit
      fi[:allowed] = hit
      allowed_by[hit] << fi[:text]
    end
  end
  { file: entry["path"], verdict: rep["verdict"], findings: findings,
    untyped_count: rep.dig("inference", "untyped_count") }
end

errors   = results.select { |r| r[:error] }
new_deg  = results.flat_map { |r| (r[:findings] || []).reject { |f| f[:hard] || f[:allowed] } }
miscomp  = results.flat_map { |r| (r[:findings] || []).select { |f| f[:hard] } }
stale    = allow.reject { |pat| allowed_by.key?(pat) }

fail_gate = !errors.empty? || !new_deg.empty? || !miscomp.empty?

if opts[:json]
  puts JSON.generate(
    pass: !fail_gate, spinel_dir: spinel_dir,
    entrypoints: results.map { |r|
      { file: r[:file], verdict: r[:verdict], error: r[:error],
        findings: (r[:findings] || []).map { |f|
          { kind: f[:kind], text: f[:text], allowed_by: f[:allowed] } } }
    },
    new_degrades: new_deg.map { |f| f[:text] },
    miscompiles: miscomp.map { |f| f[:text] },
    stale_allow: stale)
  exit(fail_gate ? 1 : 0)
end

# Human / CI report.
gh = opts[:github]
ann = ->(level, msg) { puts "::#{level}::#{msg}" if gh }

puts "spinel doctor-gate  (SPINEL_DIR=#{spinel_dir})"
results.each do |r|
  if r[:error]
    puts "  ✗ #{r[:file]}  — #{r[:error]}"
    ann.call("error", "doctor-gate: #{r[:file]}: #{r[:error]}")
    next
  end
  mark = if (r[:findings] || []).any? { |f| f[:hard] } then "✗"
         elsif (r[:findings] || []).any? { |f| !f[:allowed] } then "✗"
         elsif (r[:findings] || []).any? then "~"
         else "✓" end
  puts "  #{mark} #{r[:file]}  [#{r[:verdict]}]"
  (r[:findings] || []).each do |f|
    if f[:hard]
      tag, sym = "MISCOMPILE", "→"
    elsif f[:allowed]
      tag, sym = "allowed (#{f[:allowed]})", "·"
    else
      tag, sym = "NEW DEGRADE", "→"
    end
    puts "       #{sym} #{f[:kind]}: #{f[:text]}  — #{tag}"
    ann.call("error", "doctor-gate: #{r[:file]}: #{f[:kind]}: #{f[:text]}") unless f[:allowed]
  end
end

# Only meaningful if every entrypoint actually scanned — an errored entrypoint
# never exercised the allowlist, so its patterns aren't really "stale".
if errors.empty? && !stale.empty?
  puts "\n  stale allowlist entries (matched nothing — the degrade is gone, remove them):"
  stale.each { |p| puts "       - #{p}"; ann.call("warning", "doctor-gate: stale allowlist entry '#{p}' — remove it") }
end

puts
if fail_gate
  reasons = []
  reasons << "#{errors.size} entrypoint error(s)"   unless errors.empty?
  reasons << "#{miscomp.size} miscompile(s)"          unless miscomp.empty?
  reasons << "#{new_deg.size} new degrade(s)"         unless new_deg.empty?
  puts "  FAIL — #{reasons.join(', ')}."
  puts "         (a new degrade that's a known dead path? add its text to the allowlist.)"
else
  n_allowed = results.sum { |r| (r[:findings] || []).count { |f| f[:allowed] } }
  puts "  PASS — no new degrades#{n_allowed.positive? ? " (#{n_allowed} known degrade(s) allowlisted)" : ''}."
end
exit(fail_gate ? 1 : 0)
