# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/verifiable_style"

class VerifiableStyleTest < Minitest::Test
  def rules(source) = VerifiableStyle.violations(source).map(&:rule)

  def test_examples_are_clean
    Dir[File.expand_path("../examples/*/*.rb", __dir__)].reject { _1.match?(/probe|counterexamples/) }.each do |path|
      assert_empty VerifiableStyle.violations(File.read(path)), path
    end
  end

  def test_allowed_code
    assert_empty rules(<<~RUBY)
      module M
        Point = Data.define(:x, :y)
        module_function
        def f(a, b)
          c, d = a.divmod(b)
          p = Point.new(x: c, y: d)
          ok = !(a == b) && a != b && a <= b
          case [p.x, ok]
          in [0, true] then p.with(x: 1)
          else nil
          end
        end
      end
    RUBY
  end

  def test_flagged_code
    {
      "while true do end" => "folds",
      "[1].each { _1 }" => "folds",
      "x = 1.5" => "integers",
      "a.to_f" => "integers",
      "Time.now" => "pure",
      "puts 1" => "pure",
      "$x" => "pure",
      "@x = 1" => "pure",
      "a.send(:b)" => "no-meta",
      "a << 1" => "values",
      "a.sort!" => "values",
      "a.b = 1" => "values",
      "a[0] = 1" => "values",
      "def f; x = 1; x = 2; end" => "values",
      "def f(x); x = 2; end" => "values",
      "x += 1" => "values",
      "class String; end" => "values",
      "case x\nin 1 then 2\nend" => "case-else",
      "case x\nwhen 1 then 2\nend" => "case-else",
      "begin; 1; rescue; 2; end" => "failure"
    }.each { |source, rule| assert_includes rules(source), rule, source }
  end
end
