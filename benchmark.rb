#!/usr/bin/env ruby
# frozen_string_literal: true

require 'benchmark'
require_relative 'lib/swiss_hash'

# ============================================================
# Configuration
# ============================================================

SIZES       = [1_000, 10_000, 100_000]
ITERATIONS  = 7          # per test — enough for median, odd number
WARMUP      = 2          # discarded runs before measurement
LOOKUP_MULT = 3          # repeat lookups N times to amplify signal

# ============================================================
# Helpers
# ============================================================

def median(arr)
  sorted = arr.sort
  mid = sorted.length / 2
  sorted.length.odd? ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2.0
end

def iqr_filtered_mean(arr)
  sorted = arr.sort
  q1 = sorted[sorted.length / 4]
  q3 = sorted[3 * sorted.length / 4]
  filtered = sorted.select { |v| v >= q1 && v <= q3 }
  filtered.empty? ? median(arr) : filtered.sum / filtered.length.to_f
end

def fmt_ms(seconds)
  "%.3f ms" % (seconds * 1000)
end

def fmt_pct(a, b)
  pct = ((a - b) / b.to_f * 100)
  if pct > 0
    "\e[31m+%.1f%%\e[0m" % pct    # red = slower
  else
    "\e[32m%.1f%%\e[0m" % pct     # green = faster
  end
end

def run_timed(iterations, warmup, &block)
  # Warmup (discarded)
  warmup.times { block.call }

  # Measured runs
  times = iterations.times.map do
    GC.start
    GC.compact if GC.respond_to?(:compact)
    GC.disable

    t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    block.call
    t1 = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    GC.enable
    t1 - t0
  end

  times
end

# Generate diverse key sets
def make_string_keys(n)
  n.times.map { |i| "key_#{i}_#{'x' * (i % 17)}" }
end

def make_random_int_keys(n)
  # Pre-generate to avoid RNG cost in measurement
  rng = Random.new(42)  # deterministic seed
  n.times.map { rng.rand(n * 10) }.uniq.first(n)
end

# ============================================================
# Benchmark sections
# ============================================================

def bench_insert(label, size, key_source, iterations, warmup)
  keys = key_source.is_a?(Symbol) ? nil : key_source

  ruby_times = run_timed(iterations, warmup) do
    h = {}
    if keys
      keys.each { |k| h[k] = 1 }
    else
      size.times { |i| h[i] = i }
    end
  end

  swiss_times = run_timed(iterations, warmup) do
    h = SwissHash::Hash.new
    if keys
      keys.each { |k| h[k] = 1 }
    else
      size.times { |i| h[i] = i }
    end
  end

  ruby_med  = median(ruby_times)
  swiss_med = median(swiss_times)

  printf "  %-36s  Ruby %s   Swiss %s   %s\n",
         label, fmt_ms(ruby_med), fmt_ms(swiss_med), fmt_pct(swiss_med, ruby_med)

  [ruby_med, swiss_med]
end

def bench_lookup(label, size, ruby_hash, swiss_hash, iterations, warmup, keys: nil)
  lookup_keys = keys || (0...size).to_a

  ruby_times = run_timed(iterations, warmup) do
    LOOKUP_MULT.times do
      lookup_keys.each { |k| ruby_hash[k] }
    end
  end

  swiss_times = run_timed(iterations, warmup) do
    LOOKUP_MULT.times do
      lookup_keys.each { |k| swiss_hash[k] }
    end
  end

  ruby_med  = median(ruby_times)
  swiss_med = median(swiss_times)

  printf "  %-36s  Ruby %s   Swiss %s   %s\n",
         label, fmt_ms(ruby_med), fmt_ms(swiss_med), fmt_pct(swiss_med, ruby_med)

  [ruby_med, swiss_med]
end

def bench_delete_reinsert(label, size, iterations, warmup)
  # Measures delete/insert churn — where tombstone compaction matters
  delete_count = size / 4

  ruby_times = run_timed(iterations, warmup) do
    h = {}
    size.times { |i| h[i] = i }
    # Delete 25%
    delete_count.times { |i| h.delete(i) }
    # Reinsert same keys
    delete_count.times { |i| h[i] = i * 3 }
  end

  swiss_times = run_timed(iterations, warmup) do
    h = SwissHash::Hash.new
    size.times { |i| h[i] = i }
    delete_count.times { |i| h.delete(i) }
    delete_count.times { |i| h[i] = i * 3 }
  end

  ruby_med  = median(ruby_times)
  swiss_med = median(swiss_times)

  printf "  %-36s  Ruby %s   Swiss %s   %s\n",
         label, fmt_ms(ruby_med), fmt_ms(swiss_med), fmt_pct(swiss_med, ruby_med)

  [ruby_med, swiss_med]
end

def bench_mixed_rw(label, size, iterations, warmup)
  # 70% lookup, 20% insert, 10% delete — simulates real workload
  rng = Random.new(42)
  ops = (size * 2).times.map do
    r = rng.rand(100)
    key = rng.rand(size)
    if r < 70
      [:lookup, key]
    elsif r < 90
      [:insert, key]
    else
      [:delete, key]
    end
  end

  ruby_times = run_timed(iterations, warmup) do
    h = {}
    size.times { |i| h[i] = i }
    ops.each do |op, key|
      case op
      when :lookup then h[key]
      when :insert then h[key] = key
      when :delete then h.delete(key)
      end
    end
  end

  swiss_times = run_timed(iterations, warmup) do
    h = SwissHash::Hash.new
    size.times { |i| h[i] = i }
    ops.each do |op, key|
      case op
      when :lookup then h[key]
      when :insert then h[key] = key
      when :delete then h.delete(key)
      end
    end
  end

  ruby_med  = median(ruby_times)
  swiss_med = median(swiss_times)

  printf "  %-36s  Ruby %s   Swiss %s   %s\n",
         label, fmt_ms(ruby_med), fmt_ms(swiss_med), fmt_pct(swiss_med, ruby_med)

  [ruby_med, swiss_med]
end

# ============================================================
# Memory measurement (GC-based, more accurate than estimate)
# ============================================================

def measure_memory(n)
  GC.start
  GC.compact if GC.respond_to?(:compact)

  before = GC.stat[:heap_live_slots]
  swiss = SwissHash::Hash.new
  n.times { |i| swiss[i] = i }
  after_swiss = GC.stat[:heap_live_slots]
  swiss_slots = after_swiss - before
  swiss_stats = swiss.stats

  GC.start
  before = GC.stat[:heap_live_slots]
  ruby = {}
  n.times { |i| ruby[i] = i }
  after_ruby = GC.stat[:heap_live_slots]
  ruby_slots = after_ruby - before

  puts "  SwissHash:  #{swiss_stats[:memory_bytes] / 1024} KB native + #{swiss_slots} GC slots"
  puts "  Ruby Hash:  #{ruby_slots} GC slots (native memory not directly measurable)"
  puts "  SwissHash stats: #{swiss_stats.inspect}"
end

# ============================================================
# Main
# ============================================================

puts "SwissHash Benchmark v8"
puts "Ruby #{RUBY_VERSION} / #{RUBY_PLATFORM}"
puts "#{ITERATIONS} iterations per test, #{WARMUP} warmup, GC disabled during measurement"
puts "=" * 78
puts ""

SIZES.each do |n|
  puts "N = #{n}"
  puts "-" * 78
  printf "  %-36s  %-14s %-14s %s\n", "Test", "Ruby Hash", "SwissHash", "Delta"
  puts "  #{'─' * 74}"

  # --- Insert ---
  bench_insert("Insert (sequential int)", n, :sequential, ITERATIONS, WARMUP)
  
  if n <= 100_000
    str_keys = make_string_keys(n)
    bench_insert("Insert (string keys)", n, str_keys, ITERATIONS, WARMUP)
  end
  
  if n <= 100_000
    rand_keys = make_random_int_keys(n)
    bench_insert("Insert (random int)", n, rand_keys, ITERATIONS, WARMUP)
  end

  # --- Lookup ---
  ruby_h = {}; swiss_h = SwissHash::Hash.new
  n.times { |i| ruby_h[i] = i; swiss_h[i] = i }
  bench_lookup("Lookup (sequential int, #{LOOKUP_MULT}x)", n, ruby_h, swiss_h, ITERATIONS, WARMUP)

  if n <= 100_000
    ruby_s = {}; swiss_s = SwissHash::Hash.new
    str_keys = make_string_keys(n)
    str_keys.each { |k| ruby_s[k] = 1; swiss_s[k] = 1 }
    bench_lookup("Lookup (string keys, #{LOOKUP_MULT}x)", n, ruby_s, swiss_s, ITERATIONS, WARMUP, keys: str_keys)
  end

  # --- Delete/reinsert ---
  bench_delete_reinsert("Delete+reinsert 25%", n, ITERATIONS, WARMUP)

  # --- Mixed workload ---
  bench_mixed_rw("Mixed (70/20/10 R/W/D)", n, ITERATIONS, WARMUP)

  puts ""
end

# --- Memory ---
puts "Memory (N = 100,000)"
puts "-" * 78
measure_memory(100_000)
puts ""

# --- GC pressure comparison ---
puts "GC Pressure (N = 100,000, GC enabled)"
puts "-" * 78

# Measure how many GC runs are triggered during insert
[["Ruby Hash", -> { h = {}; 100_000.times { |i| h[i] = i }; h }],
 ["SwissHash", -> { h = SwissHash::Hash.new; 100_000.times { |i| h[i] = i }; h }]
].each do |name, work|
  GC.start
  GC.compact if GC.respond_to?(:compact)
  before_count = GC.count
  before_time  = GC.stat[:time] rescue nil  # Ruby 3.1+ has :time in ms

  result = work.call

  after_count = GC.count
  after_time  = GC.stat[:time] rescue nil

  gc_runs = after_count - before_count
  gc_time = (after_time && before_time) ? "#{after_time - before_time}ms" : "N/A"

  printf "  %-14s  GC runs: %d   GC time: %s\n", name, gc_runs, gc_time

  # Keep result alive so GC doesn't collect it mid-measurement
  result.is_a?(Hash) ? result.size : result.size
end

puts ""
puts "Done."
