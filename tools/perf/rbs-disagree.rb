#!/usr/bin/env ruby
# frozen_string_literal: true
#
# SPIKE — inferencer-disagreement localizer (spinel-dev#5, @rubys Q5).
#
# A consumer that monomorphizes before emitting (e.g. roundhouse) ships its OWN
# inferred RBS alongside the source. Spinel then re-infers from the same source.
# Where the consumer says a field/method is *concrete* but Spinel widens it to
# `untyped`, the two inferencers DISAGREE on a position that one of them got
# wrong — a candidate bug on either side, and the exact coordinate where residual
# boxing (the thing that costs you perf, spinel-dev#5 Q2) comes from.
#
# This diffs the consumer's RBS (`sig/**/*.rbs`) against Spinel's `--emit-rbs`
# and reports every (class, member) where consumer=concrete, spinel=untyped. For
# each, it locates *candidate culprits* — other writers of the same field name
# elsewhere in the program that are themselves poly — because Spinel's widening
# is whole-program, so the cause is usually a same-named slot somewhere else.
#
# It is a LOCALIZER, not an auto-reproducer: whole-program widening is subtle
# (a naive same-field-name minimal case often does NOT reproduce — confirmed),
# so the tool hands you the coordinate + the suspects + a repro scaffold, and
# you confirm the mechanism. That's the honest unit of work here.
#
# Usage:
#   SPINEL_DIR=~/sites/spinel ruby rbs-disagree.rb [--json] <entry.rb> <sig-dir> [src-root]
#     <entry.rb>  whole-program entrypoint Spinel compiles (e.g. main.rb)
#     <sig-dir>   the consumer's emitted RBS tree (e.g. sig/)
#     [src-root]  where to grep for culprit writers (default: dir of entry.rb)

require "json"

SPINEL = File.join(ENV["SPINEL_DIR"] || File.expand_path("~/sites/spinel"), "spinel")
abort "rbs-disagree: #{SPINEL} not executable (set SPINEL_DIR)" unless File.executable?(SPINEL)

json    = !!ARGV.delete("--json")
entry   = ARGV[0] or abort "usage: rbs-disagree.rb [--json] <entry.rb> <sig-dir> [src-root]"
sig_dir = ARGV[1] or abort "usage: rbs-disagree.rb [--json] <entry.rb> <sig-dir> [src-root]"
src_root = ARGV[2] || File.dirname(entry)
abort "no such entry: #{entry}"     unless File.file?(entry)
abort "no such sig dir: #{sig_dir}" unless File.directory?(sig_dir)

UNTYPED = /\buntyped\b/

# Parse an RBS string into {class_norm => {member => {type:, widened:}}}.
# Members: `def name:` (reader / method), `name=` (writer), `attr_reader/writer/
# accessor name: T`, and `@ivar: T`. attr_* expands to reader + writer.
def parse_rbs(text)
  cls = nil
  out = Hash.new { |h, k| h[k] = {} }
  text.each_line do |raw|
    l = raw.strip
    if l =~ /\A(?:class|module)\s+([A-Za-z_][\w:]*)/
      cls = norm_class($1)
    elsif l == "end"
      cls = nil
    elsif cls
      if l =~ /\Adef\s+(self\.)?([A-Za-z_]\w*[=?!]?)\s*:\s*(.+?)\s*(#.*)?\z/
        name = "#{$1}#{$2}"; type = $3; widened = !!($4 && $4 =~ /widen/i) || !!(type =~ UNTYPED)
        out[cls][name] = { type: type, widened: widened }
      elsif l =~ /\Aattr_(reader|writer|accessor)\s+([A-Za-z_]\w*)\s*:\s*(.+?)\s*(#.*)?\z/
        kind = $1; name = $2; type = $3; widened = !!(type =~ UNTYPED)
        if kind != "writer" then out[cls][name]       = { type: type, widened: widened } end
        if kind != "reader" then out[cls]["#{name}="] = { type: type, widened: widened } end
      elsif l =~ /\A@([A-Za-z_]\w*)\s*:\s*(.+?)\s*(#.*)?\z/
        out[cls]["@#{$1}"] = { type: $2, widened: !!($2 =~ UNTYPED) }
      end
    end
  end
  out
end

# Normalize a class name to a comparison key: strip namespaces (Spinel flattens
# `A::B` to `A_B`; consumers keep `A::B`), drop any `< Super`, compare on the
# leaf. Leaf-match keeps it robust to the two naming schemes.
def norm_class(name)
  name.split(/\s*<\s*/).first.to_s.gsub("::", "_").split("_").last
end

rbs_consumer = Dir.glob(File.join(sig_dir, "**", "*.rbs")).map { |f| File.read(f) }.join("\n")
consumer = parse_rbs(rbs_consumer)

tmp = "#{entry}.disagree.rbs"
unless system(SPINEL, entry, "--emit-rbs", "-o", tmp, out: File::NULL, err: File::NULL) && File.size?(tmp)
  abort "rbs-disagree: spinel --emit-rbs failed on #{entry}"
end
spinel = parse_rbs(File.read(tmp)); File.delete(tmp)

# A disagreement: consumer says concrete (not untyped), Spinel widened.
disagreements = []
consumer.each do |cls, members|
  next unless spinel.key?(cls)
  members.each do |name, cinfo|
    next if cinfo[:widened]               # consumer concrete only
    sinfo = spinel[cls][name]
    next unless sinfo && sinfo[:widened]  # spinel widened only
    disagreements << { class: cls, member: name,
                       consumer: cinfo[:type], spinel: sinfo[:type] }
  end
end

# Culprit localization: for a widened field `foo`, find same-named writers
# elsewhere whose RHS isn't obviously a concrete literal/`.to_s` — the suspects
# Spinel's whole-program writer-scan could have unified through.
rb_files = Dir.glob(File.join(src_root, "**", "*.rb"))
def culprits_for(field, rb_files)
  base = field.sub(/[=?!]\z/, "").sub(/\A@/, "")
  hits = []
  rb_files.each do |f|
    File.foreach(f).with_index(1) do |line, n|
      next unless line =~ /(?:@#{base}|\.#{base}|\bself\.#{base})\s*=/
      rhs = line.split("=", 2)[1].to_s.strip
      # skip the obviously-concrete-String writers (those aren't the wideners)
      next if rhs =~ /\A(""|".*"|\(.*\)\.to_s|.*\.to_s\b)/
      hits << { file: f.sub(%r{\A\./}, ""), line: n, code: line.strip }
    end
  end
  hits
end

by_field = disagreements.group_by { |d| d[:member].sub(/[=?!]\z/, "").sub(/\A@/, "") }
culprit_map = {}
by_field.each_key { |field| culprit_map[field] = culprits_for(field, rb_files) }

if json
  puts JSON.generate(
    entry: entry, consumer_classes: consumer.size, spinel_classes: spinel.size,
    disagreements: disagreements,
    culprits: culprit_map)
  exit(disagreements.empty? ? 0 : 1)
end

puts "rbs-disagree: #{entry}  vs  #{sig_dir}"
puts "  consumer classes #{consumer.size}   spinel classes #{spinel.size}   disagreements #{disagreements.size}"
if disagreements.empty?
  puts "  ✓ no positions where the consumer is concrete and Spinel widened."
  exit 0
end
puts
# group by class for readability
disagreements.group_by { |d| d[:class] }.sort.each do |cls, ds|
  puts "  #{cls}"
  ds.each do |d|
    printf "    ⚠ %-14s  consumer: %-10s  spinel: %s\n", d[:member], d[:consumer], d[:spinel]
  end
end
puts "\n  candidate culprits (same-named non-String writers — the whole-program suspects):"
culprit_map.each do |field, hits|
  next if hits.empty?
  puts "    #{field}:"
  hits.first(6).each { |h| printf "      %s:%-4d %s\n", h[:file], h[:line], h[:code][0, 64] }
  puts "      … +#{hits.size - 6} more" if hits.size > 6
end
puts "\n  → each ⚠ is an inferencer disagreement: the consumer monomorphized it,"
puts "    Spinel widened it. Confirm by checking whether a culprit above forces the"
puts "    field poly program-wide (a naive same-field minimal case may NOT reproduce —"
puts "    the widen is context-specific). Candidate bug on one side or the other."
exit 1
