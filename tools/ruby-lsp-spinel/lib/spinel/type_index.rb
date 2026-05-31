# frozen_string_literal: true

require "json"
require "open3"

module Spinel
  # Core, editor-agnostic logic for the Spinel ruby-lsp addon: run
  # `spinel <file> --emit-types`, index the resulting JSON by source position,
  # and answer "what type did Spinel infer at (line, col)?" plus "what degrade
  # diagnostics apply to this file?".
  #
  # No ruby-lsp dependency lives here on purpose — this is the part with real
  # logic, so it is unit-testable on its own. The addon glue (addon.rb) is a
  # thin adapter over this.
  #
  # Positions follow Prism's node.location convention: 1-based line, 0-based
  # column. That matches what `spinel --emit-types` emits, so a Prism node from
  # ruby-lsp maps to a record with no coordinate translation.
  class TypeIndex
    Entry = Struct.new(:type, :rbs, keyword_init: true)
    Diagnostic = Struct.new(:line, :col, :severity, :message, keyword_init: true)

    def initialize(spinel_bin: ENV["SPINEL_BIN"] || "spinel")
      @spinel_bin = spinel_bin
      @cache = {}    # abs path => { mtime:, by_pos:, diagnostics: }
    end

    # Inferred type at a position, or nil. Prefers a concrete type over
    # `untyped` when several nodes start at the same spot.
    def type_at(path, line, col)
      data = load(path)
      return nil unless data
      entries = data[:by_pos]["#{line}:#{col}"]
      return nil unless entries && !entries.empty?
      entries.find { |e| e.rbs != "untyped" } || entries.first
    end

    # Array<Diagnostic> for the file (empty if none / unavailable).
    def diagnostics(path)
      data = load(path)
      data ? data[:diagnostics] : []
    end

    # Seed the cache for a file from already-parsed JSON, bypassing the spinel
    # shell-out. A test seam (and usable to pre-warm from an external runner).
    def prime(path, json)
      abs = File.expand_path(path)
      data = self.class.index_json(json)
      data[:mtime] = (File.mtime(abs) if File.file?(abs))
      @cache[abs] = data
      self
    end

    # Build an index from already-parsed JSON (the unit-test entry point —
    # bypasses the spinel shell-out).
    def self.index_json(json)
      by_pos = Hash.new { |h, k| h[k] = [] }
      (json["types"] || []).each do |t|
        by_pos["#{t["line"]}:#{t["col"]}"] << Entry.new(type: t["type"], rbs: t["rbs"])
      end
      diags = (json["diagnostics"] || []).map do |d|
        Diagnostic.new(line: d["line"], col: d["col"],
                       severity: d["severity"], message: d["message"])
      end
      { by_pos: by_pos, diagnostics: diags }
    end

    private

    # Load + cache by mtime; re-runs spinel only when the file changed.
    def load(path)
      abs = File.expand_path(path)
      return nil unless File.file?(abs)

      mtime = File.mtime(abs)
      cached = @cache[abs]
      return cached if cached && cached[:mtime] == mtime

      json = run_spinel(abs)
      return nil unless json

      data = self.class.index_json(json)
      data[:mtime] = mtime
      @cache[abs] = data
      data
    end

    # Shell out to `spinel <file> --emit-types -o <tmp>` and parse the JSON.
    # Returns nil on any failure (missing binary, compile error in the file,
    # etc.) so the addon degrades to "no Spinel info" rather than erroring.
    def run_spinel(abs)
      out = "#{abs}.spinel-types.json"
      _stdout, _stderr, status = Open3.capture3(
        @spinel_bin, abs, "--emit-types", "-o", out
      )
      return nil unless status.success? && File.file?(out)

      JSON.parse(File.read(out))
    rescue StandardError
      nil
    ensure
      File.delete(out) if out && File.exist?(out)
    end
  end
end
