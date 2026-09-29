# frozen_string_literal: true

module LeanTranslator
  # Reads a module's type annotations and Data classes, and prints the Lean type declarations.
  module Schema
    Sig = Data.define(:params, :ret, :raises)
    Model = Data.define(:enums, :unions, :records, :functions)

    module_function

    def build(mod, comments)
      annotations = comments.filter_map do |c|
        [c.location.start_line + 1, c.slice.delete_prefix("#:").strip] if c.slice.start_with?("#:")
      end.to_h
      aliases = comments.filter_map { |c| c.slice.match(/\A#\s*@rbs type (\w+) = (.+)\z/)&.captures }
      enums, unions = aliases.partition { |_, rhs| rhs.strip.start_with?(":") }.map do |list|
        list.to_h { |name, rhs| [name, rhs.split("|").map { _1.strip.delete_prefix(":") }] }
      end
      kinds = enums.transform_values { :enum }.merge(unions.transform_values { :union })
      body = mod.body&.body || []
      body.each { check_top(_1) }
      records = body.grep(Prism::ConstantWriteNode).to_h { record(_1, annotations, kinds) }
      functions = body.grep(Prism::DefNode).to_h { function(_1, annotations, kinds) }
      unions.values.flatten.each do |member|
        raise Unsupported, "union member #{member} is not a Data class in this module" unless records.key?(member)
      end
      Model.new(enums:, unions:, records:, functions:)
    end

    def check_top(node)
      return if node.is_a?(Prism::ConstantWriteNode) || (node.is_a?(Prism::DefNode) && node.receiver.nil?)
      return if node.is_a?(Prism::CallNode) && node.name == :module_function && node.receiver.nil? && node.arguments.nil?

      raise Text.unsupported(node, "only Data.define constants, module_function and def are allowed at module level")
    end

    def record(node, annotations, kinds)
      call = node.value
      unless call.is_a?(Prism::CallNode) && call.name == :define && call.receiver&.slice == "Data"
        raise Text.unsupported(node, "only `Name = Data.define(...)` constants are supported")
      end

      names = (call.arguments&.arguments || []).map do |arg|
        arg.is_a?(Prism::SymbolNode) ? arg.unescaped : raise(Text.unsupported(arg, "Data fields must be symbols"))
      end
      text = annotation(node, annotations, "#: (Type, ...)")
      types = Types.split_list(text.delete_prefix("(").delete_suffix(")")).map { Types.parse(_1, kinds) }
      raise Text.unsupported(node, "#{names.size} fields but #{types.size} types") unless types.size == names.size

      [node.name.to_s, names.zip(types)]
    end

    def function(node, annotations, kinds)
      args, ret = annotation(node, annotations, "#: (Type, ...) -> Type").match(/\A\((.*)\)\s*->\s*(.+)\z/)&.captures
      raise Text.unsupported(node, "annotation must look like `#: (Type, ...) -> Type`") unless ret

      params = node.parameters
      names = params ? params.requireds.map { _1.name.to_s } : []
      if params && [params.optionals, params.posts, params.keywords].any?(&:any?) ||
         params && (params.rest || params.keyword_rest || params.block)
        raise Text.unsupported(node, "only plain positional parameters are supported")
      end
      types = Types.split_list(args).map { Types.parse(_1, kinds) }
      raise Text.unsupported(node, "#{names.size} parameters but #{types.size} types") unless types.size == names.size

      [node.name.to_s, Sig.new(params: names.zip(types), ret: Types.parse(ret, kinds), raises: raises?(node.body))]
    end

    def annotation(node, annotations, shape)
      annotations.fetch(node.location.start_line) do
        raise Text.unsupported(node, "needs a `#{shape}` comment on the line above")
      end
    end

    def raises?(node)
      return false if node.nil?

      (node.is_a?(Prism::CallNode) && node.name == :raise && node.receiver.nil?) ||
        node.compact_child_nodes.any? { raises?(_1) }
    end

    # Fields every member of the union has, with the same type.
    def common_fields(model, union)
      members = model.unions.fetch(union)
      model.records.fetch(members.first).select { |field| members.all? { model.records.fetch(_1).include?(field) } }
    end

    def declarations(model)
      members = model.unions.values.flatten
      [
        *model.enums.map { |name, values| enum_decl(name, values) },
        *model.records.reject { |name, _| members.include?(name) }.map { |name, fields| structure_decl(name, fields) },
        *model.unions.map { |name, classes| union_decl(name, classes, model.records) },
        *model.unions.keys.flat_map { |name| accessors(model, name) }
      ]
    end

    def enum_decl(name, values)
      ["inductive #{Types.type_name(name)}", *values.map { "  | #{_1}" }, "  deriving DecidableEq, Repr"]
    end

    def structure_decl(name, fields)
      ["structure #{name} where", *fields.map { |f, t| "  #{f} : #{Types.lean(t)}" }, "  deriving DecidableEq, Repr"]
    end

    def union_decl(name, classes, records)
      ctors = classes.map { |c| "  | #{[Types.ctor_name(c), Types.binders(records.fetch(c))].reject(&:empty?).join(' ')}" }
      ["inductive #{Types.type_name(name)}", *ctors, "  deriving DecidableEq, Repr"]
    end

    def accessors(model, union)
      type = Types.type_name(union)
      common_fields(model, union).map do |field, field_type|
        cases = model.unions.fetch(union).map do |c|
          [".#{Types.ctor_name(c)}", *model.records.fetch(c).map { |f, _| f == field ? field : "_" }].join(" ")
        end
        ["def #{type}.#{field} : #{type} → #{Types.lean(field_type)}", "  | #{cases.join(' | ')} => #{field}"]
      end
    end
  end
end
