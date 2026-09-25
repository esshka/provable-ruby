# frozen_string_literal: true

require_relative "money_split"

def render(name, total, parts)
  MoneySplit.public_send(name, total, parts).join(" ")
rescue ArgumentError => e
  "error: #{e.message}"
end

$stdin.each_line do |line|
  name, total, parts = line.split(" => ").first.split
  puts "#{name} #{total} #{parts} => #{render(name, Integer(total), Integer(parts))}"
end
