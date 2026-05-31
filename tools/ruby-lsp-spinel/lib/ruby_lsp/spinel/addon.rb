# frozen_string_literal: true

require "ruby_lsp/addon"
require "spinel/type_index"

module RubyLsp
  module Spinel
    # Spinel-aware ruby-lsp addon. Surfaces the AOT compiler's whole-program
    # type inference in the editor: hover over a call / ivar / constant to see
    # the type Spinel inferred, and a warning when a value or method degraded to
    # the boxed `untyped` (poly) slow path — the silent-miscompile signal.
    #
    # Data comes from `spinel <file> --emit-types` (see ::Spinel::TypeIndex).
    #
    # Note on ruby-lsp 0.26: the hover entry point isn't handed the document
    # URI, so we capture it from the code-lens entry point (which is, and which
    # fires for every displayed document) and reuse it for hover. Push-style
    # diagnostics aren't an addon extension point in this version, so degrade
    # warnings ride along on hover rather than appearing as squiggles.
    class Addon < ::RubyLsp::Addon
      def activate(global_state, outgoing_queue)
        @index = ::Spinel::TypeIndex.new
        @current_uri = nil
      end

      def deactivate; end

      def name
        "Spinel"
      end

      def version
        "0.1.0"
      end

      # Code lens fires per displayed document and (unlike hover) receives the
      # URI. We emit no lenses — we only use it to learn the current file so
      # hover can look up positions in the right file.
      def create_code_lens_listener(response_builder, uri, dispatcher)
        @current_uri = uri
        nil
      end

      def create_hover_listener(response_builder, node_context, dispatcher)
        return unless @current_uri

        path = @current_uri.to_standardized_path
        return unless path

        Hover.new(@index, path, response_builder, dispatcher)
      end

      # Hover listener: on the cursor node, look up Spinel's inferred type at
      # that exact (line, col) and render it. Registers for the node kinds the
      # hover request can target (its ALLOWED_TARGETS — bare locals aren't in
      # that set, a ruby-lsp limitation).
      class Hover
        def initialize(index, path, response_builder, dispatcher)
          @index = index
          @path = path
          @response_builder = response_builder
          dispatcher.register(
            self,
            :on_call_node_enter,
            :on_instance_variable_read_node_enter,
            :on_instance_variable_write_node_enter,
            :on_constant_read_node_enter,
          )
        end

        def on_call_node_enter(node) = annotate(node)
        def on_instance_variable_read_node_enter(node) = annotate(node)
        def on_instance_variable_write_node_enter(node) = annotate(node)
        def on_constant_read_node_enter(node) = annotate(node)

        private

        # Prism node.location is 1-based line / 0-based column — the same
        # convention `spinel --emit-types` emits, so no translation is needed.
        def annotate(node)
          loc = node.location
          entry = @index.type_at(@path, loc.start_line, loc.start_column)
          return unless entry

          if entry.rbs == "untyped"
            @response_builder.push(
              "**Spinel** infers `untyped` — ⚠️ boxed poly slow path",
              category: :documentation,
            )
          else
            @response_builder.push(
              "**Spinel** infers `#{entry.rbs}`",
              category: :documentation,
            )
          end
        end
      end
    end
  end
end
