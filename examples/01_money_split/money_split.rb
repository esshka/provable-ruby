# frozen_string_literal: true

module MoneySplit
  module_function

  def remainder_last(total, parts)
    raise ArgumentError, "parts must be positive" unless parts.positive?
    raise ArgumentError, "total must not be negative" if total.negative?

    base = total / parts
    Array.new(parts - 1, base) + [total - (base * (parts - 1))]
  end

  def even(total, parts)
    raise ArgumentError, "parts must be positive" unless parts.positive?
    raise ArgumentError, "total must not be negative" if total.negative?

    base, extra = total.divmod(parts)
    Array.new(parts) { |i| i < extra ? base + 1 : base }
  end
end
