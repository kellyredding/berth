module Berth
  module Format
    extend self

    def table(rows : Array(Array(String))) : String
      return "" if rows.empty?
      widths = rows.first.size.times.map { |column| rows.max_of { |row| row[column]?.try(&.size) || 0 } }.to_a
      rows.map do |row|
        row.map_with_index { |cell, column| column == row.size - 1 ? cell : cell.ljust(widths[column]) }
          .join("  ").rstrip
      end.join("\n")
    end

    # Text no longer than `width`, ending in … when it was cut.
    def cut(text : String, width : Int32) : String
      text.size <= width ? text : "#{text[0, width - 1].rstrip}…"
    end

    def on_off(value : Bool) : String
      value ? "on" : "off"
    end

    # A login's steps in words: `google (op://V/I)`, `google email from op://V/I`.
    def steps(steps : Array(Config::Step)) : String
      steps.map do |step|
        if from = step.email_from
          "#{step.flow} email from #{from}"
        else
          "#{step.flow} (#{step.item})"
        end
      end.join(", then ")
    end
  end
end
