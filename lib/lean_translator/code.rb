# frozen_string_literal: true

module LeanTranslator
  # Prints one Ruby method as a Lean `def`. Guards become `if … else`, locals become `let`,
  # `case/in` becomes `match`. Any Ruby it does not know raises Unsupported rather than guessing.
  module Code
    Ctx = Data.define(:model, :mode)
    Arm = Data.define(:node, :combos, :guard, :bindings)

    BINARY = {
      :+ => "+", :- => "-", :* => "*", :/ => "/", :% => "%",
      :< => "<", :<= => "≤", :> => ">", :>= => "≥", :== => "=", :!= => "≠"
    }.freeze
    COMPARISONS = %i[< <= > >= == !=].freeze
    PREDICATES = { positive?: "> 0", negative?: "< 0", zero?: "= 0" }.freeze

    module_function

    def function(name, sig, node, model)
      mode = mode(sig, node)
      result = mode == :except ? "Except String #{Text.atom(Types.lean(sig.ret))}" : Types.lean(sig.ret)
      head = ["def", name, Types.binders(sig.params), ":", result, ":="].reject(&:empty?).join(" ")
      [head, *Text.indent(block(statements(node.body, node), sig.params.to_h, Ctx.new(model:, mode:)))]
    end

    # :except when the method raises, :option when it returns `T?`, else :plain.
    def mode(sig, node)
      option = sig.ret.first == :option
      raise Text.unsupported(node, "a method cannot both raise and return nil") if sig.raises && option

      if sig.raises then :except
      elsif option then :option
      else :plain
      end
    end

    def statements(body, owner)
      raise Text.unsupported(owner, "expected a plain body (no rescue, no empty branch)") unless body.is_a?(Prism::StatementsNode)

      body.body
    end

    # Statements in tail position: each one either guards, binds, or is the result.
    def block(stmts, env, ctx)
      first, *rest = stmts
      return tail(first, env, ctx) if rest.empty?

      case first
      in Prism::IfNode | Prism::UnlessNode if guard?(first)
        cond = first.is_a?(Prism::UnlessNode) ? negate(first.predicate, env, ctx) : expr(first.predicate, env, ctx).first
        exit_line = tail(first.statements.body.first, env, ctx)
        ["if #{cond} then #{exit_line.fetch(0)} else", *block(rest, env, ctx)]
      in Prism::LocalVariableWriteNode
        code, type = expr(first.value, env, ctx)
        if type.first == :option
          option_match(first, rest, code, type, env, ctx)
        else
          ["let #{first.name} := #{code}", *block(rest, env.merge(first.name.to_s => type), ctx)]
        end
      in Prism::MultiWriteNode
        divmod(first, rest, env, ctx)
      else
        raise Text.unsupported(first, "only guards and local bindings may come before the result")
      end
    end

    def guard?(node)
      other = node.is_a?(Prism::IfNode) ? node.subsequent : node.else_clause
      body = node.statements&.body || []
      other.nil? && body.size == 1 &&
        (body[0].is_a?(Prism::ReturnNode) || (body[0].is_a?(Prism::CallNode) && body[0].name == :raise))
    end

    # `x = f(...)` where f returns `T?`, then `x ? a : b`, is a match on the option.
    def option_match(write, rest, code, type, env, ctx)
      name = write.name.to_s
      choice = rest.first
      unless rest.size == 1 && choice.is_a?(Prism::IfNode) && choice.subsequent.is_a?(Prism::ElseNode) &&
             choice.predicate.is_a?(Prism::LocalVariableReadNode) && choice.predicate.name.to_s == name
        raise Text.unsupported(write, "a nil-able local must be followed only by `#{name} ? … : …`")
      end

      some = block(statements(choice.statements, choice), env.merge(name => type[1]), ctx)
      none = block(statements(choice.subsequent.statements, choice), env.except(name), ctx)
      ["match #{code} with", *Text.arm("| some #{name}", some), *Text.arm("| none", none)]
    end

    def divmod(write, rest, env, ctx)
      value = write.value
      targets = write.lefts
      unless value.is_a?(Prism::CallNode) && value.name == :divmod && value.arguments&.arguments&.size == 1 &&
             targets.size == 2 && targets.all?(Prism::LocalVariableTargetNode) && write.rest.nil? && write.rights.empty?
        raise Text.unsupported(write, "multiple assignment is supported only as `q, r = a.divmod(b)`")
      end

      a, type = expr(value.receiver, env, ctx)
      b, = expr(value.arguments.arguments[0], env, ctx)
      q, r = targets.map { _1.name.to_s }
      ["let #{q} := #{Text.operand(a)} / #{Text.operand(b)}", "let #{r} := #{Text.operand(a)} % #{Text.operand(b)}",
       *block(rest, env.merge(q => type, r => type), ctx)]
    end

    def tail(node, env, ctx)
      case node
      in Prism::IfNode if node.subsequent
        no = if node.subsequent.is_a?(Prism::ElseNode)
               block(statements(node.subsequent.statements, node), env, ctx)
             else
               tail(node.subsequent, env, ctx)
             end
        branch(expr(node.predicate, env, ctx).first, block(statements(node.statements, node), env, ctx), no)
      in Prism::CaseMatchNode then match(node, env, ctx)
      in Prism::ReturnNode if node.arguments&.arguments&.size == 1 then tail(node.arguments.arguments[0], env, ctx)
      in Prism::NilNode if ctx.mode == :option then ["none"]
      in Prism::CallNode if node.name == :raise && node.receiver.nil?
        message = node.arguments&.arguments&.last
        unless ctx.mode == :except && message.is_a?(Prism::StringNode)
          raise Text.unsupported(node, "raise needs the form `raise ArgumentError, \"message\"`")
        end

        [".error #{string(message)}"]
      else
        code, type = expr(node, env, ctx)
        [leaf(code, type, ctx)]
      end
    end

    def leaf(code, type, ctx)
      case ctx.mode
      when :except then ".ok #{Text.atom(code)}"
      when :option then type.first == :option ? code : "some #{Text.atom(code)}"
      else code
      end
    end

    def branch(cond, yes, no)
      one_line = "if #{cond} then #{yes[0]} else #{no[0]}"
      return [one_line] if yes.size == 1 && no.size == 1 && one_line.size <= 80

      ["if #{cond} then", *Text.indent(yes), *(no.size == 1 ? ["else #{no[0]}"] : ["else", *Text.indent(no)])]
    end

    def match(node, env, ctx)
      subjects = node.predicate.is_a?(Prism::ArrayNode) ? node.predicate.elements : [node.predicate]
      typed = subjects.map { expr(_1, env, ctx) }
      raise Text.unsupported(node, "case/in needs an explicit else") unless node.else_clause

      fallback = block(statements(node.else_clause.statements, node), env, ctx)
      arms = node.conditions.map { arm(_1, typed.map(&:last), ctx) }
      check_fallthrough(arms)
      ["match #{typed.map(&:first).join(', ')} with",
       *arms.flat_map { arm_lines(_1, env, ctx, fallback) },
       *Text.arm("| #{(['_'] * subjects.size).join(', ')}", fallback)]
    end

    def arm(in_node, types, ctx)
      pattern, guard = in_node.pattern.is_a?(Prism::IfNode) ? [in_node.pattern.statements.body[0], in_node.pattern.predicate] : [in_node.pattern, nil]
      elems = types.size == 1 ? [pattern] : tuple(pattern, types.size)
      choices = elems.zip(types).map { |pat, type| alternatives(pat, type, ctx) }
      combos = choices.first.product(*choices.drop(1))
      Arm.new(node: in_node, combos:, guard:, bindings: combos.first.map(&:last).reduce({}, :merge))
    end

    def tuple(pattern, size)
      return pattern.requireds if pattern.is_a?(Prism::ArrayPatternNode) && pattern.constant.nil? &&
                                  pattern.rest.nil? && pattern.posts.empty? && pattern.requireds.size == size

      raise Text.unsupported(pattern, "pattern must be a #{size}-element array like the case subject")
    end

    # Each alternative is [Lean pattern, key for overlap checks, {bound name => type}].
    def alternatives(pattern, type, ctx)
      case pattern
      in Prism::AlternationPatternNode then alternatives(pattern.left, type, ctx) + alternatives(pattern.right, type, ctx)
      in Prism::SymbolNode then [[".#{pattern.unescaped}", [:sym, pattern.unescaped], {}]]
      in Prism::ConstantReadNode then [constructor(pattern, pattern.name.to_s, {}, ctx)]
      in Prism::HashPatternNode if pattern.constant.is_a?(Prism::ConstantReadNode) && pattern.rest.nil?
        [constructor(pattern, pattern.constant.name.to_s, pattern.elements.to_h { binding(_1) }, ctx)]
      in Prism::LocalVariableTargetNode then [[pattern.name.to_s, [:any], { pattern.name.to_s => type }]]
      else raise Text.unsupported(pattern, "unsupported pattern `#{pattern.slice}`")
      end
    end

    def binding(assoc)
      key = assoc.key.unescaped
      var = case assoc.value
            in nil then key
            in Prism::ImplicitNode then assoc.value.value.name.to_s
            in Prism::LocalVariableTargetNode then assoc.value.name.to_s
            else raise Text.unsupported(assoc, "only `field:` or `field: name` may appear inside a class pattern")
            end
      [key, var]
    end

    def constructor(node, cls, binds, ctx)
      raise Text.unsupported(node, "#{cls} is not a member of a `# @rbs type` union") unless union_of(cls, ctx.model)

      fields = ctx.model.records.fetch(cls)
      unknown = binds.keys - fields.map(&:first)
      raise Text.unsupported(node, "#{cls} has no field #{unknown.join(', ')}") if unknown.any?

      code = [".#{Types.ctor_name(cls)}", *fields.map { |f, _| binds.fetch(f, "_") }].join(" ")
      [code, [:ctor, cls], fields.select { |f, _| binds.key?(f) }.to_h { |f, t| [binds.fetch(f), t] }]
    end

    # Ruby tries later arms when a guard fails; Lean's `else` below goes straight to the fallback,
    # which is only the same when no later arm could match.
    def check_fallthrough(arms)
      arms.each_with_index do |arm, i|
        next unless arm.guard

        later = arms.drop(i + 1).flat_map(&:combos)
        next unless later.any? { |b| arm.combos.any? { |a| overlap?(a.map { _1[1] }, b.map { _1[1] }) } }

        raise Text.unsupported(arm.node, "if this guard fails, Ruby tries a later arm that can match; reorder the arms")
      end
    end

    def overlap?(keys_a, keys_b) = keys_a.zip(keys_b).all? { |a, b| a == [:any] || b == [:any] || a == b }

    def arm_lines(arm, env, ctx, fallback)
      head = arm.combos.map { |combo| "| #{combo.map(&:first).join(', ')}" }.join(" ")
      inner = env.merge(arm.bindings)
      body = block(statements(arm.node.statements, arm.node), inner, ctx)
      body = branch(expr(arm.guard, inner, ctx).first, body, fallback) if arm.guard
      Text.arm(head, body)
    end

    def union_of(cls, model) = model.unions.find { |_, members| members.include?(cls) }&.first

    def negate(node, env, ctx)
      code = expr(node, env, ctx).first
      "¬ #{node.is_a?(Prism::AndNode) || node.is_a?(Prism::OrNode) ? "(#{code})" : Text.operand(code)}"
    end

    def string(node)
      text = node.unescaped
      raise Text.unsupported(node, "only plain printable strings are supported") unless text.match?(/\A[[:print:]]*\z/)

      "\"#{text.gsub('\\', '\\\\\\\\').gsub('"', '\\"')}\""
    end

    # Returns [Lean code, type].
    def expr(node, env, ctx)
      case node
      in Prism::IntegerNode then [node.value.negative? ? "(#{node.value})" : node.value.to_s, [:int]]
      in Prism::StringNode then [string(node), [:string]]
      in Prism::SymbolNode then [".#{node.unescaped}", [:sym]]
      in Prism::TrueNode then ["true", [:bool]]
      in Prism::FalseNode then ["false", [:bool]]
      in Prism::LocalVariableReadNode
        type = env.fetch(node.name.to_s) { raise Text.unsupported(node, "unknown local #{node.name}") }
        type == [:nat] ? ["(#{node.name} : Int)", [:int]] : [node.name.to_s, type]
      in Prism::ArrayNode
        items = node.elements.map { expr(_1, env, ctx) }
        ["[#{items.map(&:first).join(', ')}]", [:list, items.first&.last || [:any]]]
      in Prism::ParenthesesNode if node.body.is_a?(Prism::StatementsNode) && node.body.body.size == 1
        code, type = expr(node.body.body[0], env, ctx)
        ["(#{code})", type]
      in Prism::AndNode then logic(node, "∧", env, ctx)
      in Prism::OrNode then logic(node, "∨", env, ctx)
      in Prism::IfNode if node.subsequent.is_a?(Prism::ElseNode)
        yes, type = expr(single(node.statements, node), env, ctx)
        no, = expr(single(node.subsequent.statements, node), env, ctx)
        ["if #{expr(node.predicate, env, ctx).first} then #{yes} else #{no}", type]
      in Prism::CallNode then call(node, env, ctx)
      else raise Text.unsupported(node, "unsupported expression `#{node.slice}`")
      end
    end

    def logic(node, op, env, ctx)
      left, = expr(node.left, env, ctx)
      right, = expr(node.right, env, ctx)
      ["#{Text.operand(left)} #{op} #{Text.operand(right)}", [:bool]]
    end

    def single(stmts, owner)
      body = statements(stmts, owner)
      raise Text.unsupported(owner, "a branch used as a value must be one expression") unless body.size == 1

      body[0]
    end

    def call(node, env, ctx)
      name = node.name
      args = node.arguments&.arguments || []
      recv = node.receiver
      return function_call(node, args, env, ctx) if recv.nil?
      return construct(node, args, env, ctx) if name == :new && recv.is_a?(Prism::ConstantReadNode)
      return min_max(node, env, ctx) if %i[min max].include?(name) && recv.is_a?(Prism::ArrayNode) && args.empty?

      code, type = expr(recv, env, ctx)
      if name == :! then [negate(recv, env, ctx), [:bool]]
      elsif BINARY.key?(name) && args.size == 1
        right, = expr(args[0], env, ctx)
        op = name == :+ && type.first == :list ? "++" : BINARY.fetch(name)
        ["#{Text.operand(code)} #{op} #{Text.operand(right)}", COMPARISONS.include?(name) ? [:bool] : type]
      elsif PREDICATES.key?(name) && args.empty? then ["#{Text.atom(code)} #{PREDICATES.fetch(name)}", [:bool]]
      elsif name == :include? && args.size == 1 then ["#{Text.atom(expr(args[0], env, ctx).first)} ∈ #{Text.atom(code)}", [:bool]]
      elsif name == :with then ["{ #{Text.atom(code)} with #{fields(node, args, env, ctx)} }", type]
      elsif %i[length size].include?(name) && args.empty? then ["(#{Text.atom(code)}.length : Int)", [:int]]
      elsif name == :sum && args.empty? && node.block.nil? then ["#{Text.atom(code)}.sum", type[1]]
      elsif %i[map select].include?(name) && args.empty? then map(node, code, type, env, ctx)
      elsif name == :reduce && args.size == 1 then reduce(node, code, type, args[0], env, ctx)
      elsif args.empty? && node.block.nil? && (field = field_type(type, name.to_s, ctx.model))
        ["#{Text.atom(code)}.#{name}", field]
      else raise Text.unsupported(node, "unsupported call `#{node.slice}`")
      end
    end

    def function_call(node, args, env, ctx)
      sig = ctx.model.functions.fetch(node.name.to_s) do
        raise Text.unsupported(node, "unknown method #{node.name}")
      end
      raise Text.unsupported(node, "calling a method that raises is not supported") if sig.raises

      [[node.name.to_s, *args.map { Text.atom(expr(_1, env, ctx).first) }].join(" "), sig.ret]
    end

    def construct(node, args, env, ctx)
      cls = node.receiver.name.to_s
      return array_new(node, args, env, ctx) if cls == "Array"

      fields = ctx.model.records.fetch(cls) { raise Text.unsupported(node, "#{cls} is not a Data class in this module") }
      union = union_of(cls, ctx.model)
      return ["{ #{fields(node, args, env, ctx)} }", [:record, cls]] unless union

      given = keyword_args(node, args, env, ctx).to_h
      codes = fields.map do |f, _|
        raise Text.unsupported(node, "missing field #{f}") unless given.key?(f)

        Text.atom(given.fetch(f) || f)
      end
      [["#{Types.type_name(union)}.#{Types.ctor_name(cls)}", *codes].join(" "), [:union, union]]
    end

    def array_new(node, args, env, ctx)
      count = Text.atom(expr(args[0], env, ctx).first) if args.any?
      if args.size == 2 && node.block.nil?
        value, type = expr(args[1], env, ctx)
        ["List.replicate #{count}.toNat #{Text.atom(value)}", [:list, type]]
      elsif args.size == 1 && node.block
        index, = block_params(node, 1)
        body, type = expr(block_body(node), env.merge(index => [:nat]), ctx)
        ["(List.range #{count}.toNat).map fun (#{index} : Nat) => #{body}", [:list, type]]
      else
        raise Text.unsupported(node, "Array.new needs (n, value) or (n) { |i| ... }")
      end
    end

    def map(node, code, type, env, ctx)
      item, = block_params(node, 1)
      body, body_type = expr(block_body(node), env.merge(item => type[1]), ctx)
      if node.name == :map
        ["#{Text.atom(code)}.map fun #{item} => #{body}", [:list, body_type]]
      else
        ["#{Text.atom(code)}.filter fun #{item} => decide (#{body})", type]
      end
    end

    def reduce(node, code, type, init, env, ctx)
      acc, item = block_params(node, 2)
      start, start_type = expr(init, env, ctx)
      body = block_body(node)
      if body.is_a?(Prism::CallNode) && body.receiver.nil? && body.block.nil? &&
         body.arguments&.arguments&.map { _1.is_a?(Prism::LocalVariableReadNode) && _1.name.to_s } == [acc, item]
        function_call(body, [], env, ctx) # checks the method exists and does not raise
        return ["#{Text.atom(code)}.foldl #{body.name} #{Text.atom(start)}", start_type]
      end

      step, = expr(body, env.merge(acc => start_type, item => type[1]), ctx)
      ["#{Text.atom(code)}.foldl (fun #{acc} #{item} => #{step}) #{Text.atom(start)}", start_type]
    end

    def min_max(node, env, ctx)
      items = node.receiver.elements.map { expr(_1, env, ctx) }
      raise Text.unsupported(node, "only [a, b].#{node.name} is supported") unless items.size == 2

      ["#{node.name} #{items.map { Text.atom(_1.first) }.join(' ')}", items[0].last]
    end

    def block_params(node, count)
      params = node.block.is_a?(Prism::BlockNode) && node.block.parameters
      names = params.is_a?(Prism::BlockParametersNode) ? params.parameters&.requireds&.map { _1.name.to_s } : nil
      raise Text.unsupported(node, "block needs exactly #{count} named parameter(s)") unless names&.size == count

      names
    end

    def block_body(node) = single(node.block.body, node)

    def keyword_args(node, args, env, ctx)
      unless args.size == 1 && args[0].is_a?(Prism::KeywordHashNode) && args[0].elements.all?(Prism::AssocNode)
        raise Text.unsupported(node, "expected keyword arguments")
      end

      args[0].elements.map do |assoc|
        value = assoc.value.is_a?(Prism::ImplicitNode) ? nil : expr(assoc.value, env, ctx).first
        [assoc.key.unescaped, value]
      end
    end

    def fields(node, args, env, ctx)
      keyword_args(node, args, env, ctx).map { |key, value| value ? "#{key} := #{value}" : key }.join(", ")
    end

    def field_type(type, field, model)
      fields = case type
               in [:record, name] then model.records.fetch(name)
               in [:union, name] then Schema.common_fields(model, name)
               else return nil
               end
      fields.to_h[field]
    end
  end
end
