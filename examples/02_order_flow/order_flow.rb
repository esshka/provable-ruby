# frozen_string_literal: true

module OrderFlow
  # @rbs type status = :placed | :paid | :shipped | :cancelled
  # @rbs type event = Pay | Ship | Cancel | Refund

  #: (status, Integer, Integer, Integer, Array[Integer])
  Order  = Data.define(:status, :total, :paid, :refunded, :seen)
  #: (Integer, Integer)
  Pay    = Data.define(:id, :amount)
  #: (Integer)
  Ship   = Data.define(:id)
  #: (Integer)
  Cancel = Data.define(:id)
  #: (Integer, Integer)
  Refund = Data.define(:id, :amount)

  module_function

  #: (Integer) -> Order
  def start(total)
    raise ArgumentError, "total must be positive" unless total.positive?

    Order.new(status: :placed, total:, paid: 0, refunded: 0, seen: [])
  end

  #: (Order, event) -> Order?
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

  #: (Order, event) -> Order
  def step(order, event)
    return order if order.seen.include?(event.id)

    nxt = apply(order, event)
    nxt ? nxt.with(seen: order.seen + [event.id]) : order
  end

  #: (Order, Array[event]) -> Order
  def run(order, events)
    events.reduce(order) { |acc, event| step(acc, event) }
  end
end
