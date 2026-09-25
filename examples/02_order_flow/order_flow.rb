# frozen_string_literal: true

module OrderFlow
  Order  = Data.define(:status, :total, :paid, :refunded, :seen)
  Pay    = Data.define(:id, :amount)
  Ship   = Data.define(:id)
  Cancel = Data.define(:id)
  Refund = Data.define(:id, :amount)

  module_function

  def start(total)
    raise ArgumentError, "total must be positive" unless total.positive?

    Order.new(status: :placed, total:, paid: 0, refunded: 0, seen: [])
  end

  def apply(order, event)
    case [order.status, event]
    in [:placed, Pay(amount:)] if amount.positive? && order.paid + amount <= order.total
      paid = order.paid + amount
      order.with(paid:, status: paid == order.total ? :paid : :placed)
    in [:paid, Ship]
      order.with(status: :shipped)
    in [:placed | :paid, Cancel]
      order.with(status: :cancelled)
    in [:cancelled, Refund(amount:)] if amount.positive? && order.refunded + amount <= order.paid
      order.with(refunded: order.refunded + amount)
    else
      nil
    end
  end

  def step(order, event)
    return order if order.seen.include?(event.id)

    nxt = apply(order, event)
    nxt ? nxt.with(seen: order.seen + [event.id]) : order
  end

  def run(order, events)
    events.reduce(order) { |acc, event| step(acc, event) }
  end
end
