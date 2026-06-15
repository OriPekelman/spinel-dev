#!/usr/bin/env ruby
# frozen_string_literal: true
#
# spinel-probe — emit a capability / layout manifest for a Spinel checkout.
#
# A fast-moving matz/master changes things downstream tooling and Makefiles
# hardcode: where the Ruby backend lives, whether `spinel` is a C binary or a
# shell driver, which --emit-* flags exist, and how the compiler signals an
# unlowerable call (silent emit-0 vs a hard error). Every other tool here used
# to re-discover those facts ad hoc — the version-guard debt that accreted and
# then had to be deleted. This probe discovers them once, so tools (and a
# downstream `SPINEL_DEPS`) adapt at one well-tested point. See docs/09.
#
# Usage:
#   spinel-probe.rb [--json]
# Env:
#   SPINEL_DIR  (default ~/sites/spinel)   SPINEL_BIN  (default $SPINEL_DIR/spinel)
#
# Exit 0 if the compiler is usable (driver + a working `puts 1` compile), else 2.

require "json"
require "tmpdir"
require "open3"

json = !!ARGV.delete("--json")
SPINEL_DIR = ENV["SPINEL_DIR"] || File.join(Dir.home, "sites", "spinel")
SPINEL = ENV["SPINEL_BIN"] || File.join(SPINEL_DIR, "spinel")

abort "spinel-probe: #{SPINEL} not found/executable (set SPINEL_DIR or SPINEL_BIN)" unless File.executable?(SPINEL)

# ---- static layout/driver detection (no compile) --------------------------
magic = File.binread(SPINEL, 4) rescue ""
driver =
  if magic.start_with?("\x7fELF".b) then "c-binary"      # ELF (resolved through any symlink)
  elsif magic.start_with?("#!")     then "shell-driver"  # the legacy /bin/sh wrapper
  else "unknown"
  end

legacy_split = File.file?(File.join(SPINEL_DIR, "legacy", "spinel_analyze.rb"))
legacy_root  = File.file?(File.join(SPINEL_DIR, "spinel_analyze.rb"))
legacy_dir   = legacy_split ? File.join(SPINEL_DIR, "legacy") : (legacy_root ? SPINEL_DIR : nil)
layout       = legacy_split ? "legacy-split" : (legacy_root ? "root" : "c-only")
runtime_lib  = [File.join(SPINEL_DIR, "lib")].find { |p| File.exist?(File.join(p, "libspinel_rt.a")) }

# ---- dynamic capability probes (compile trivial programs) -----------------
usable = false
flags = []
error_model = "unknown"
symbol_map_mode = "unknown"

Dir.mktmpdir("spinel_probe") do |w|
  # A method-bearing program: --emit-rbs/-types/-symbol-map all need a user
  # method to produce non-empty output to recognize.
  hello = File.join(w, "h.rb")
  File.write(hello, "def f(x)\n  x + 1\nend\nputs f(1)\n")

  # Basic: does it compile + run? (the compiler is usable at all)
  hbin = File.join(w, "h")
  usable = !!(system(SPINEL, hello, "-o", hbin, out: File::NULL, err: File::NULL) && File.size?(hbin))

  # --debug: compiles + runs (don't trust the flag name; trust the artifact).
  dbin = File.join(w, "hd")
  flags << "--debug" if system(SPINEL, "--debug", hello, "-o", dbin, out: File::NULL, err: File::NULL) && File.size?(dbin)

  # NB: mode flags go BEFORE the source — the legacy shell driver stops parsing
  # flags at the first source file, so a flag after it is silently ignored (and
  # the program just compiles to a binary at the -o path). The C driver is
  # order-independent, so before-source is safe for both.

  # --emit-types: must produce a parseable types JSON. A spinel too old for the
  # flag instead compiles `hello` to a binary at the output path (non-JSON).
  tj = File.join(w, "t.json")
  if system(SPINEL, "--emit-types", hello, "-o", tj, out: File::NULL, err: File::NULL) && File.size?(tj)
    flags << "--emit-types" if (JSON.parse(File.read(tj))["types"] rescue nil)
  end

  # --emit-rbs: text RBS (a `class`/`def`/module/comment), not a compiled binary.
  rb = File.join(w, "t.rbs")
  if system(SPINEL, "--emit-rbs", hello, "-o", rb, out: File::NULL, err: File::NULL) && File.size?(rb)
    head = File.read(rb, 64).to_s
    flags << "--emit-rbs" if head =~ /\A\s*(#|class\b|def\b|module\b)/
  end

  # --emit-symbol-map: a JSON object with a "symbols" array.
  sj = File.join(w, "t.symbols.json")
  flag_map = system(SPINEL, "--emit-symbol-map", hello, "-o", sj, out: File::NULL, err: File::NULL) &&
             File.size?(sj) && (JSON.parse(File.read(sj))["symbols"].is_a?(Array) rescue false)
  flags << "--emit-symbol-map" if flag_map

  # symbol_map_mode: does setting SPINEL_EMIT_SYMBOL_MAP on a `-c` run still
  # produce compilable C (legacy: ride-along), or an empty .c (the C compiler's
  # emit-ONLY mode)? Tools must emit the map in a separate run when emit-only.
  # "n/a" when the compiler emits no map at all (pre-#1345 legacy).
  sjc = File.join(w, "m.symbols.json")
  cfile = File.join(w, "m.c")
  system({ "SPINEL_EMIT_SYMBOL_MAP" => sjc }, SPINEL, hello, "-c", "-o", cfile, out: File::NULL, err: File::NULL)
  symbol_map_mode =
    if    !File.size?(sjc)              then "n/a"
    elsif File.size?(cfile).to_i > 0    then "ride-along"
    else                                     "emit-only"
    end

  # error_model: how does the compiler signal a call it can't lower? Compile a
  # call to an undefined method on a user object and read the diagnostics.
  unres = File.join(w, "u.rb")
  File.write(unres, "class Foo\n  def bar(x)\n    x.no_such_method_xyz\n  end\nend\np Foo.new.bar(Foo.new)\n")
  out, _st = Open3.capture2e(SPINEL, unres, "-c", "-o", File.join(w, "u.c"))
  error_model =
    if    out =~ /cannot resolve call.*emitting 0/m then "emit-0"   # legacy: silent degrade
    elsif out =~ /^spinel: (unsupported|.*unsupported type)/m then "strict" # C: hard error
    else  "unknown"
    end
end

manifest = {
  spinel_dir: SPINEL_DIR,
  spinel_bin: SPINEL,
  usable: usable,
  driver: driver,
  layout: layout,
  legacy_dir: legacy_dir,
  runtime_lib: runtime_lib,
  flags: flags,
  error_model: error_model,
  symbol_map_mode: symbol_map_mode,
}

if json
  puts JSON.generate(manifest)
else
  puts "spinel-probe: #{SPINEL}"
  printf "  usable           %s\n", (usable ? "yes" : "NO — `puts 1` did not compile")
  printf "  driver           %s\n", driver
  printf "  layout           %s%s\n", layout, (legacy_dir ? "  (Ruby backend: #{legacy_dir})" : "")
  printf "  runtime lib      %s\n", (runtime_lib || "(not found)")
  printf "  flags            %s\n", (flags.empty? ? "(none detected)" : flags.join(" "))
  printf "  error model      %s%s\n", error_model,
         (error_model == "strict" ? "  (hard-errors on an unlowerable call)" :
          error_model == "emit-0" ? "  (silently emits 0 — legacy)" : "")
  printf "  symbol-map mode  %s%s\n", symbol_map_mode,
         (symbol_map_mode == "emit-only" ? "  (emit it in a SEPARATE run from codegen)" :
          symbol_map_mode == "ride-along" ? "  (rides along a normal -c run)" : "")
end

exit(usable ? 0 : 2)
