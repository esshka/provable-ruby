# frozen_string_literal: true

require "prism"

# Flags Ruby outside the verifiable subset (README: "Verifiable Ruby").
module VerifiableStyle
  Violation = Data.define(:line, :rule, :message)

  NODE_RULES = {
    Prism::WhileNode => ["folds", "no while; use map/select/reduce"],
    Prism::UntilNode => ["folds", "no until; use map/select/reduce"],
    Prism::ForNode => ["folds", "no for; use map/select/reduce"],
    Prism::BreakNode => ["folds", "no break"],
    Prism::NextNode => ["folds", "no next"],
    Prism::RedoNode => ["folds", "no redo"],
    Prism::RetryNode => ["failure", "no retry"],
    Prism::RescueNode => ["failure", "no rescue in the core; let errors surface"],
    Prism::RescueModifierNode => ["failure", "no rescue modifier; let errors surface"],
    Prism::EnsureNode => ["failure", "no ensure in the core"],
    Prism::FloatNode => ["integers", "no Float; use integer cents or units"],
    Prism::RationalNode => ["integers", "no Rational literals"],
    Prism::ImaginaryNode => ["integers", "no Imaginary literals"],
    Prism::ClassNode => ["values", "no classes or reopened classes; use Data.define in a module"],
    Prism::SingletonClassNode => ["values", "no class << self"],
    Prism::XStringNode => ["pure", "no shell commands"]
  }.freeze

  META_CALLS = %i[
    send __send__ public_send define_method method_missing respond_to_missing?
    instance_variable_get instance_variable_set eval instance_eval class_eval module_eval
    instance_exec class_exec const_get const_set
  ].freeze
  IMPURE_CALLS = %i[puts print p pp gets rand srand sleep system exec spawn fork require load open exit abort at_exit].freeze
  LOOP_CALLS = %i[loop each each_with_index times upto downto].freeze
  MUTATING_CALLS = %i[
    << push append pop shift unshift prepend concat insert delete delete_at delete_if
    keep_if clear replace fill store update attr_writer attr_accessor
  ].freeze
  FLOAT_CALLS = %i[to_f Float fdiv to_r Rational].freeze
  NOT_SETTERS = %i[== != <= >= === =~].freeze
  IMPURE_CONSTANTS = %i[
    Time Date DateTime Random File IO Dir ENV Kernel Process Thread ObjectSpace
    Float BigDecimal Rational STDIN STDOUT STDERR ARGV
  ].freeze

  module_function

  def violations(source)
    result = Prism.parse(source)
    raise ArgumentError, result.errors.map(&:message).join("; ") if result.failure?

    walk(result.value)
  end

  def walk(node)
    check(node) + node.compact_child_nodes.flat_map { walk(_1) }
  end

  def check(node)
    name = node.class.name.split("::").last
    case node
    when *NODE_RULES.keys then [violation(node, *NODE_RULES.fetch(node.class))]
    when Prism::CallNode then [call_rule(node)].compact.map { violation(node, *_1) }
    when Prism::ConstantReadNode
      IMPURE_CONSTANTS.include?(node.name) ? [violation(node, "pure", "no #{node.name}: I/O, clock, randomness or floats")] : []
    when Prism::CaseNode, Prism::CaseMatchNode
      node.else_clause ? [] : [violation(node, "case-else", "case needs an explicit else")]
    when Prism::DefNode then reassignments(node)
    else
      if name.match?(/GlobalVariable|InstanceVariable|ClassVariable|BackReference|NumberedReference/)
        [violation(node, "pure", "no globals, instance or class variables")]
      elsif name.match?(/OperatorWriteNode|OrWriteNode|AndWriteNode/)
        [violation(node, "values", "no +=, ||= or &&=; bind a new name")]
      else
        []
      end
    end
  end

  def call_rule(node)
    name = node.name
    if META_CALLS.include?(name) then ["no-meta", "no #{name}"]
    elsif IMPURE_CALLS.include?(name) && node.receiver.nil? then ["pure", "no #{name}: I/O, randomness or loading"]
    elsif LOOP_CALLS.include?(name) then ["folds", "no #{name}; use map/select/reduce"]
    elsif FLOAT_CALLS.include?(name) then ["integers", "no #{name}"]
    elsif MUTATING_CALLS.include?(name) || bang?(name) || setter?(name) then ["values", "no mutation (#{name}); use with or a new value"]
    end
  end

  def bang?(name) = name != :! && name.end_with?("!")

  def setter?(name) = name.end_with?("=") && !NOT_SETTERS.include?(name)

  # ponytail: one scope per def, so two blocks binding the same name are flagged; track block scopes if that bites.
  def reassignments(defn)
    params = param_names(defn.parameters)
    local_writes(defn.body).reduce([params, []]) do |(seen, found), write|
      if seen.include?(write.name)
        [seen, found + [violation(write, "values", "#{write.name} is reassigned; bind a new name")]]
      else
        [seen + [write.name], found]
      end
    end.last
  end

  def param_names(node)
    return [] if node.nil?

    own = node.class.name.end_with?("ParameterNode") && node.respond_to?(:name) ? [node.name] : []
    (own + node.compact_child_nodes.flat_map { param_names(_1) }).compact
  end

  # Pattern captures (`in Pay(amount:)`) are not writes, so only these two forms count.
  def local_writes(node)
    case node
    when nil, Prism::DefNode then []
    when Prism::LocalVariableWriteNode then [node] + local_writes(node.value)
    when Prism::MultiWriteNode then node.lefts.grep(Prism::LocalVariableTargetNode) + local_writes(node.value)
    else node.compact_child_nodes.flat_map { local_writes(_1) }
    end
  end

  def violation(node, rule, message) = Violation.new(line: node.location.start_line, rule:, message:)
end
