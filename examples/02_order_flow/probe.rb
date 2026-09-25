# frozen_string_literal: true

require_relative "order_flow"

EVENTS = {
  "pay" => OrderFlow::Pay,
  "ship" => OrderFlow::Ship,
  "cancel" => OrderFlow::Cancel,
  "refund" => OrderFlow::Refund
}.freeze

def event(token)
  kind, *args = token.split(":")
  EVENTS.fetch(kind).new(*args.map { Integer(_1) })
end

def render(total, events)
  order = OrderFlow.run(OrderFlow.start(total), events)
  "#{order.status} #{order.total} #{order.paid} #{order.refunded} #{order.seen.inspect}"
rescue ArgumentError => e
  "error: #{e.message}"
end

$stdin.each_line do |line|
  input = line.split(" => ").first
  total, *tokens = input.split
  puts "#{input} => #{render(Integer(total), tokens.map { event(_1) })}"
end
