# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "prism"

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))
require "spinel/type_index"

# Unit tests for the editor-agnostic core: indexing + position lookup.
class TypeIndexTest < Minitest::Test
  def with_file(src)
    Dir.mktmpdir do |dir|
      path = File.join(dir, "x.rb")
      File.write(path, src)
      yield path
    end
  end

  def test_type_at_and_prefer_concrete
    with_file("c.bump(5)\n") do |path|
      json = {
        "types" => [
          { "file" => path, "line" => 1, "col" => 0, "type" => "poly", "rbs" => "untyped" },
          { "file" => path, "line" => 1, "col" => 0, "type" => "int", "rbs" => "Integer" },
          { "file" => path, "line" => 1, "col" => 7, "type" => "int", "rbs" => "Integer" },
        ],
        "diagnostics" => [],
      }
      idx = Spinel::TypeIndex.new.prime(path, json)
      # Same position has both untyped and Integer -> prefer the concrete one.
      assert_equal("Integer", idx.type_at(path, 1, 0).rbs)
      assert_equal("Integer", idx.type_at(path, 1, 7).rbs)
      assert_nil(idx.type_at(path, 99, 99))
    end
  end

  def test_untyped_surfaces
    with_file("x\n") do |path|
      json = { "types" => [{ "file" => path, "line" => 1, "col" => 0, "type" => "poly", "rbs" => "untyped" }],
               "diagnostics" => [] }
      idx = Spinel::TypeIndex.new.prime(path, json)
      assert_equal("untyped", idx.type_at(path, 1, 0).rbs)
    end
  end

  def test_diagnostics
    with_file("def show(x)\n  x\nend\n") do |path|
      json = { "types" => [],
               "diagnostics" => [{ "file" => path, "line" => 1, "col" => 0,
                                   "severity" => "warning", "message" => "Spinel: `show` widened" }] }
      idx = Spinel::TypeIndex.new.prime(path, json)
      d = idx.diagnostics(path)
      assert_equal(1, d.size)
      assert_equal("warning", d.first.severity)
    end
  end
end

# Integration test: drive the real ruby-lsp hover path (dispatcher +
# ResponseBuilders::Hover) through the addon's hover listener.
class HoverIntegrationTest < Minitest::Test
  def setup
    require "ruby_lsp/internal"
    require "ruby_lsp/spinel/addon"
  rescue LoadError => e
    skip("ruby-lsp not available: #{e.message}")
  end

  def test_hover_renders_inferred_type
    Dir.mktmpdir do |dir|
      path = File.join(dir, "x.rb")
      src = "c.bump(5)\n"
      File.write(path, src)
      json = { "types" => [{ "file" => path, "line" => 1, "col" => 0, "type" => "int", "rbs" => "Integer" }],
               "diagnostics" => [] }

      addon = RubyLsp::Spinel::Addon.new
      addon.instance_variable_set(:@index, Spinel::TypeIndex.new.prime(path, json))
      addon.instance_variable_set(:@current_uri, URI::Generic.from_path(path: path))

      dispatcher = Prism::Dispatcher.new
      builder = RubyLsp::ResponseBuilders::Hover.new
      addon.create_hover_listener(builder, nil, dispatcher)

      call_node = Prism.parse(src).value.statements.body.first
      dispatcher.dispatch_once(call_node)

      assert_includes(builder.response, "Spinel")
      assert_includes(builder.response, "Integer")
    end
  end

  def test_hover_warns_on_untyped
    Dir.mktmpdir do |dir|
      path = File.join(dir, "x.rb")
      src = "obj.handle(1)\n"
      File.write(path, src)
      json = { "types" => [{ "file" => path, "line" => 1, "col" => 0, "type" => "poly", "rbs" => "untyped" }],
               "diagnostics" => [] }

      addon = RubyLsp::Spinel::Addon.new
      addon.instance_variable_set(:@index, Spinel::TypeIndex.new.prime(path, json))
      addon.instance_variable_set(:@current_uri, URI::Generic.from_path(path: path))

      dispatcher = Prism::Dispatcher.new
      builder = RubyLsp::ResponseBuilders::Hover.new
      addon.create_hover_listener(builder, nil, dispatcher)

      dispatcher.dispatch_once(Prism.parse(src).value.statements.body.first)
      assert_includes(builder.response, "boxed poly slow path")
    end
  end
end
