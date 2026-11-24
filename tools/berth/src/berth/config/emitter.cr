module Berth
  module Config
    # Writes a config tree as JSON in the starter's style: sections in canonical
    # order, every other key in its existing order, two-space indent, arrays of
    # plain values on one line, and each flat object in an array (a sign-in
    # step) on its own line.
    module Emitter
      extend self

      def emit(root : Hash(String, JSON::Any)) : String
        ordered = root.to_a.sort_by! { |key, _| SECTIONS.index(key) || SECTIONS.size }
        String.build do |io|
          value(io, JSON::Any.new(ordered.to_h), 0)
          io << '\n'
        end
      end

      private def value(io : IO, node : JSON::Any, depth : Int32, in_array : Bool = false) : Nil
        case raw = node.raw
        when Hash
          if raw.empty?
            io << "{}"
          elsif in_array && raw.values.all? { |item| plain?(item) }
            io << '{' << raw.map { |key, item| "#{key.to_json}: #{item.to_json}" }.join(", ") << '}'
          else
            io << "{\n"
            raw.each_with_index do |(key, item), index|
              io << ",\n" if index > 0
              io << "  " * (depth + 1) << key.to_json << ": "
              value(io, item, depth + 1)
            end
            io << '\n' << "  " * depth << '}'
          end
        when Array
          if raw.all? { |item| plain?(item) }
            io << '[' << raw.map(&.to_json).join(", ") << ']'
          else
            io << "[\n"
            raw.each_with_index do |item, index|
              io << ",\n" if index > 0
              io << "  " * (depth + 1)
              value(io, item, depth + 1, in_array: true)
            end
            io << '\n' << "  " * depth << ']'
          end
        else
          io << node.to_json
        end
      end

      private def plain?(node : JSON::Any) : Bool
        !(node.as_h? || node.as_a?)
      end
    end
  end
end
