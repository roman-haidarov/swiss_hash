#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative 'lib/swiss_hash'

SIZES       = [1_000, 10_000, 100_000]
ITERATIONS  = 21
WARMUP      = 5
LOOKUP_MULT = 3

def median(a)
  s = a.sort
  m = s.length / 2
  s.length.odd? ? s[m] : (s[m - 1] + s[m]) / 2.0
end

def stddev(a)
  return 0.0 if a.length < 2
  mean = a.sum / a.length.to_f
  Math.sqrt(a.map { |x| (x - mean) ** 2 }.sum / (a.length - 1))
end

def iqr_mean(a)
  s = a.sort
  q1_idx = s.length / 4
  q3_idx = 3 * s.length / 4
  mid = s[q1_idx...q3_idx]
  mid.empty? ? median(a) : mid.sum / mid.length.to_f
end

def fmt_ms(sec)
  "%.3f" % (sec * 1000)
end

def fmt_pct(a, b)
  pct = ((a - b) / b.to_f * 100)
  if pct > 0
    "\e[31m+%6.2f%%\e[0m" % pct
  else
    "\e[32m%7.2f%%\e[0m" % pct
  end
end

def timed_once(&block)
  GC.start
  GC.disable
  t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  block.call
  t1 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  GC.enable
  t1 - t0
end

def run_pair(iterations, warmup, ruby_block, swiss_block)
  warmup.times { ruby_block.call }
  warmup.times { swiss_block.call }

  ruby_times = []
  swiss_times = []

  iterations.times do |i|
    if i.even?
      ruby_times  << timed_once(&ruby_block)
      swiss_times << timed_once(&swiss_block)
    else
      swiss_times << timed_once(&swiss_block)
      ruby_times  << timed_once(&ruby_block)
    end
  end

  [ruby_times, swiss_times]
end

def report(label, ruby_times, swiss_times)
  rm  = iqr_mean(ruby_times)
  sm  = iqr_mean(swiss_times)
  r_std = stddev(ruby_times) / (ruby_times.sum / ruby_times.length.to_f) * 100
  s_std = stddev(swiss_times) / (swiss_times.sum / swiss_times.length.to_f) * 100

  printf "  %-38s  Ruby %6s ms (±%4.1f%%)   Swiss %6s ms (±%4.1f%%)   %s\n",
         label, fmt_ms(rm), r_std, fmt_ms(sm), s_std, fmt_pct(sm, rm)
end

def make_string_keys(n)
  n.times.map { |i| "key_#{i}_#{'x' * (i % 17)}" }
end

def make_random_int_keys(n)
  rng = Random.new(42)
  n.times.map { rng.rand(n * 10) }.uniq.first(n)
end

def smoke_test!
  print "Running smoke tests... "

  # Basic int
  h = SwissHash::Hash.new
  100.times { |i| h[i] = i * 2 }
  100.times { |i| raise "int lookup failed at #{i}" unless h[i] == i * 2 }
  raise "size mismatch" unless h.size == 100

  # Strings
  hs = SwissHash::Hash.new
  keys = make_string_keys(100)
  keys.each_with_index { |k, i| hs[k] = i }
  keys.each_with_index { |k, i| raise "str lookup failed at #{k}" unless hs[k] == i }

  # Delete
  hd = SwissHash::Hash.new
  10.times { |i| hd[i] = i }
  5.times { |i| hd.delete(i) }
  raise "delete size" unless hd.size == 5
  5.times { |i| raise "deleted still present" if hd[i] }
  (5..9).each { |i| raise "non-deleted missing at #{i}" unless hd[i] == i }

  # Missing key returns nil
  hm = SwissHash::Hash.new
  hm["exists"] = 1
  raise "missing key returned non-nil" unless hm["nope"].nil?

  puts "ok"
end

def bench_insert_seq_int(size, iter, warmup)
  ruby_times, swiss_times = run_pair(iter, warmup,
    -> { h = {}; size.times { |i| h[i] = i } },
    -> { h = SwissHash::Hash.new; size.times { |i| h[i] = i } }
  )
  report("Insert (sequential int)", ruby_times, swiss_times)
end

def bench_insert_str(size, keys, iter, warmup)
  ruby_times, swiss_times = run_pair(iter, warmup,
    -> { h = {};                keys.each { |k| h[k] = 1 } },
    -> { h = SwissHash::Hash.new; keys.each { |k| h[k] = 1 } }
  )
  report("Insert (string keys)", ruby_times, swiss_times)
end

def bench_insert_rand_int(size, keys, iter, warmup)
  ruby_times, swiss_times = run_pair(iter, warmup,
    -> { h = {};                keys.each { |k| h[k] = 1 } },
    -> { h = SwissHash::Hash.new; keys.each { |k| h[k] = 1 } }
  )
  report("Insert (random int)", ruby_times, swiss_times)
end

def bench_lookup(label, ruby_h, swiss_h, keys, iter, warmup)
  ruby_times, swiss_times = run_pair(iter, warmup,
    -> { LOOKUP_MULT.times { keys.each { |k| ruby_h[k]  } } },
    -> { LOOKUP_MULT.times { keys.each { |k| swiss_h[k] } } }
  )
  report(label, ruby_times, swiss_times)
end

def bench_delete_reinsert(size, iter, warmup)
  dc = size / 4
  ruby_times, swiss_times = run_pair(iter, warmup,
    -> {
      h = {}
      size.times { |i| h[i] = i }
      dc.times { |i| h.delete(i) }
      dc.times { |i| h[i] = i * 3 }
    },
    -> {
      h = SwissHash::Hash.new
      size.times { |i| h[i] = i }
      dc.times { |i| h.delete(i) }
      dc.times { |i| h[i] = i * 3 }
    }
  )
  report("Delete+reinsert 25%", ruby_times, swiss_times)
end

def bench_mixed(size, iter, warmup)
  rng = Random.new(42)
  ops = (size * 2).times.map do
    r = rng.rand(100); key = rng.rand(size)
    if    r < 70 then [:lookup, key]
    elsif r < 90 then [:insert, key]
    else              [:delete, key]
    end
  end

  ruby_times, swiss_times = run_pair(iter, warmup,
    -> {
      h = {}
      size.times { |i| h[i] = i }
      ops.each { |op, key|
        case op
        when :lookup then h[key]
        when :insert then h[key] = key
        when :delete then h.delete(key)
        end
      }
    },
    -> {
      h = SwissHash::Hash.new
      size.times { |i| h[i] = i }
      ops.each { |op, key|
        case op
        when :lookup then h[key]
        when :insert then h[key] = key
        when :delete then h.delete(key)
        end
      }
    }
  )
  report("Mixed (70/20/10 R/W/D)", ruby_times, swiss_times)
end

puts "SwissHash Benchmark — honest edition"
puts "Ruby #{RUBY_VERSION} / #{RUBY_PLATFORM}"
puts "#{ITERATIONS} iterations (IQR-filtered mean), #{WARMUP} warmup, interleaved Ruby/Swiss"
puts "=" * 100
puts ""

smoke_test!
puts ""

SIZES.each do |n|
  puts "N = #{n}"
  puts "-" * 100
  printf "  %-38s  %-28s  %-28s  %s\n", "Test", "Ruby Hash", "SwissHash", "Delta"
  puts "  #{'─' * 98}"

  bench_insert_seq_int(n, ITERATIONS, WARMUP)

  str_keys = make_string_keys(n)
  bench_insert_str(n, str_keys, ITERATIONS, WARMUP)

  rand_keys = make_random_int_keys(n)
  bench_insert_rand_int(n, rand_keys, ITERATIONS, WARMUP)

  ruby_h = {}; swiss_h = SwissHash::Hash.new
  n.times { |i| ruby_h[i] = i; swiss_h[i] = i }
  bench_lookup("Lookup (sequential int, #{LOOKUP_MULT}x)",
               ruby_h, swiss_h, (0...n).to_a, ITERATIONS, WARMUP)

  ruby_s = {}; swiss_s = SwissHash::Hash.new
  str_keys.each { |k| ruby_s[k] = 1; swiss_s[k] = 1 }
  bench_lookup("Lookup (string keys, #{LOOKUP_MULT}x)",
               ruby_s, swiss_s, str_keys, ITERATIONS, WARMUP)

  bench_delete_reinsert(n, ITERATIONS, WARMUP)
  bench_mixed(n, ITERATIONS, WARMUP)

  puts ""
end

puts "Memory (N = 100,000)"
puts "-" * 100
GC.start
before = GC.stat[:heap_live_slots]
swiss = SwissHash::Hash.new
100_000.times { |i| swiss[i] = i }
swiss_slots = GC.stat[:heap_live_slots] - before
stats = swiss.stats

GC.start
before = GC.stat[:heap_live_slots]
ruby = {}
100_000.times { |i| ruby[i] = i }
ruby_slots = GC.stat[:heap_live_slots] - before

puts "  SwissHash:  #{stats[:memory_bytes] / 1024} KB native + #{swiss_slots} GC slots"
puts "  Ruby Hash:  #{ruby_slots} GC slots (native memory not directly measurable)"
puts "  Load factor: #{(stats[:load_factor] * 100).round(1)}%, SIMD: #{stats[:simd]}"
puts ""

puts "Done."
