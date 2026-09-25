# frozen_string_literal: true

require_relative "money_split"

xs = MoneySplit.remainder_last(11, 4)
fair = xs.max <= xs.min + 1
puts "#{fair ? 'NOT REPRODUCED' : 'REPRODUCED'} remainder_last_is_not_fair: " \
     "remainder_last(11, 4) = #{xs.inspect}"
exit(fair ? 1 : 0)
