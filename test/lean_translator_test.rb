# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/lean_translator"

class LeanTranslatorTest < Minitest::Test
  def lean(body) = LeanTranslator.translate("module M\n  module_function\n\n#{body}end\n", path: "m.rb").last

  def assert_unsupported(body, message)
    error = assert_raises(LeanTranslator::Unsupported) { lean(body) }
    assert_match message, error.message
  end

  def test_readme_late_fee
    out = lean(<<~RUBY)
      #: (Integer, Integer) -> Integer
      def fee(amount_due, days_late)
        return 0 unless amount_due.positive? && days_late.positive?

        [days_late * 50, 5_000].min
      end
    RUBY
    assert_includes out, "def fee (amount_due days_late : Int) : Int :="
    assert_includes out, "if ¬ (amount_due > 0 ∧ days_late > 0) then 0 else"
    assert_includes out, "min (days_late * 50) 5000"
  end

  def test_map_and_reduce
    out = lean(<<~RUBY)
      #: (Array[Integer]) -> Integer
      def total(xs)
        xs.map { |x| x * 2 }.reduce(0) { |acc, x| acc + x }
      end
    RUBY
    assert_includes out, "(xs.map fun x => x * 2).foldl (fun acc x => acc + x) 0"
  end

  def test_needs_annotation
    assert_unsupported "def f(x)\n  x\nend\n", /line 4: needs a `#: \(Type, \.\.\.\) -> Type`/
  end

  def test_rejects_unknown_code
    assert_unsupported "#: (Integer) -> Integer\ndef f(x)\n  x.to_s\nend\n", /line 6: unsupported call `x.to_s`/
  end

  def test_rejects_guard_that_falls_through
    assert_unsupported <<~RUBY, /if this guard fails/
      #: (Integer) -> Integer
      def f(x)
        case x
        in n if n.positive? then 1
        in n then 2
        else 3
        end
      end
    RUBY
  end
end
