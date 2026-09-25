# frozen_string_literal: true

require_relative "order_flow"

include OrderFlow

shipped = run(start(100), [Pay.new(id: 1, amount: 100), Ship.new(id: 2)])
after = run(shipped, [Cancel.new(id: 3), Refund.new(id: 4, amount: 100)])
reproduced = after.paid == 100 && after.refunded.zero?
puts "#{reproduced ? 'REPRODUCED' : 'NOT REPRODUCED'} refund_not_always_possible: " \
     "paid #{after.paid}, status #{after.status}, refunded #{after.refunded} after cancel + refund"
exit(reproduced ? 0 : 1)
