#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative 'lib/swiss_hash'

N = 100_000

def make_string_keys(n)
  n.times.map { |i| "key_#{i}_#{'x' * (i % 17)}" }
end

puts "Setting up SwissHash with #{N} string keys..."
swiss = SwissHash::Hash.new
keys = make_string_keys(N)
keys.each { |k| swiss[k] = 1 }

puts "PID: #{Process.pid}"
puts "Running infinite lookup loop. Ctrl+C to stop."
puts "Run in another terminal:"
puts "  sample #{Process.pid} 30 -f /tmp/swiss.sample"
puts "  sleep 5s"
sleep 7
puts "=== Starting infinite lookup loop ==="

GC.disable

# while true
100.times do
  keys.each { |k| swiss[k] }
end
