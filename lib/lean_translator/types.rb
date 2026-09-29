# frozen_string_literal: true

module LeanTranslator
  # A type is an array: [:int], [:nat], [:string], [:bool], [:list, t], [:option, t],
  # [:enum, alias], [:union, alias] or [:record, class name].
  module Types
    SCALARS = { "Integer" => [:int], "String" => [:string], "bool" => [:bool] }.freeze
    LEAN_SCALARS = { int: "Int", nat: "Nat", string: "String", bool: "Bool" }.freeze

    module_function

    # Parses RBS type text; aliases maps a `# @rbs type` name to :enum or :union.
    def parse(text, aliases)
      text = text.strip
      if text.end_with?("?") then [:option, parse(text.chomp("?"), aliases)]
      elsif (inner = text[/\AArray\[(.+)\]\z/, 1]) then [:list, parse(inner, aliases)]
      elsif SCALARS.key?(text) then SCALARS.fetch(text)
      elsif aliases.key?(text) then [aliases.fetch(text), text]
      elsif text.match?(/\A[A-Z]\w*\z/) then [:record, text]
      else raise Unsupported, "unknown type #{text}"
      end
    end

    # Splits "A, Array[B], C" at top-level commas.
    def split_list(text)
      depth = 0
      text.each_char.with_object([+""]) do |ch, parts|
        depth += 1 if "[(".include?(ch)
        depth -= 1 if "])".include?(ch)
        ch == "," && depth.zero? ? parts << +"" : parts.last << ch
      end.map(&:strip).reject(&:empty?)
    end

    def lean(type)
      case type
      in [:list, inner] then "List #{Text.atom(lean(inner))}"
      in [:option, inner] then "Option #{Text.atom(lean(inner))}"
      in [:enum | :union, name] then type_name(name)
      in [:record, name] then name
      in [scalar] then LEAN_SCALARS.fetch(scalar)
      end
    end

    def type_name(alias_name) = alias_name[0].upcase + alias_name[1..]

    def ctor_name(class_name) = class_name[0].downcase + class_name[1..]

    # [["a", t], ["b", t]] => "(a b : T)"
    def binders(pairs)
      pairs.chunk_while { |a, b| a.last == b.last }
           .map { |group| "(#{group.map(&:first).join(' ')} : #{lean(group.first.last)})" }
           .join(" ")
    end
  end
end
