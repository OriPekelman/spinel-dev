#!/usr/bin/env ruby
# frozen_string_literal: true
#
# DEPRECATED — matz/spinel now ships a first-party `spinel-flatten` (tools/, compiled
# by spinel, cc-only). Prefer it; this Ruby spike is kept only as a no-build fallback.
#
# SPIKE — spinel-flatten: inline a `require_relative` graph into one self-contained
# `.rb` (spinel-dev#10 part 3). Turns a gem's failing smoke test into a single
# file `spinel-reduce` can ddmin, so the gem → minimal-repro pipeline is automatic:
#
#   ruby spinel-flatten.rb smoke.rb -o flat.rb
#   SPINEL_DIR=~/sites/spinel ruby spinel-reduce.rb --target sp_box_int flat.rb
#
# It resolves `require_relative` depth-first, in place (a file's definitions land
# before its use, preserving Ruby load order), dedupes repeated requires, drops
# unresolvable ones with a marker (exactly as Spinel silently does — and the
# `require` check in `doctor` flags), and leaves non-relative `require` (stdlib)
# lines untouched.
#
# Usage: ruby spinel-flatten.rb [-o out.rb] <entry-or-smoke.rb>

oi = ARGV.index("-o")
out = oi ? ARGV.delete_at(oi + 1) : nil
ARGV.delete("-o") if oi
entry = ARGV[0] or abort "usage: spinel-flatten.rb [-o out.rb] <entry.rb>"
abort "no such file: #{entry}" unless File.file?(entry)

# `require_relative "x"` / `require_relative 'x'`, capturing indent + path.
REQ_REL = /\A(\s*)require_relative\s+(["'])(.+?)\2\s*(?:#.*)?\z/

included = {}    # realpath -> true (dedup)
out_lines = []

# Resolve a require_relative arg against the requiring file's dir (with/without .rb).
def resolve(arg, from_dir)
  base = File.expand_path(arg, from_dir)
  [base, "#{base}.rb"].each { |c| return c if File.file?(c) }
  nil
end

inline = lambda do |path|
  rp = (File.realpath(path) rescue path)
  return if included[rp]
  included[rp] = true
  dir = File.dirname(path)
  File.readlines(path).each do |line|
    m = line.match(REQ_REL)
    unless m
      out_lines << line
      next
    end
    indent, _q, arg = m[1], m[2], m[3]
    target = resolve(arg, dir)
    if target.nil?
      out_lines << "#{indent}# spinel-flatten: unresolved require_relative #{arg.inspect} (dropped, as Spinel would)\n"
    elsif included[(File.realpath(target) rescue target)]
      out_lines << "#{indent}# spinel-flatten: require_relative #{arg.inspect} already inlined\n"
    else
      out_lines << "#{indent}# spinel-flatten: <<< #{File.basename(target)}\n"
      inline.call(target)
      out_lines << "#{indent}# spinel-flatten: >>> #{File.basename(target)}\n"
    end
  end
end

inline.call(entry)

text = "# Flattened by spinel-flatten from #{entry} (#{included.size} file(s) inlined).\n" + out_lines.join
text += "\n" unless text.end_with?("\n")

if out
  File.write(out, text)
  $stderr.puts "spinel-flatten: #{entry} -> #{out}  (#{included.size} file(s), #{out_lines.size} lines)"
else
  print text
end
