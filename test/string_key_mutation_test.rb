# frozen_string_literal: true

# Targeted regression test for Ruby Hash-compatible String key semantics.
#
# Ruby Hash protects String keys from later mutation by storing a stable key.
# SwissHash::Hash should do the same if it wants to behave like Hash.
#
# Run:
#   bundle exec ruby test/string_key_mutation_test.rb

require_relative "../lib/swiss_hash"

class AssertionFailure < StandardError; end

TestCase = Struct.new(:name, :body, keyword_init: true)

TESTS = []

def test(name, &body)
  TESTS << TestCase.new(name: name, body: body)
end

def mutable_string(value)
  String.new(value)
end

def assert(condition, message)
  raise AssertionFailure, message unless condition
end

def refute(condition, message)
  raise AssertionFailure, message if condition
end

def assert_equal(expected, actual, message = nil)
  return if expected == actual

  detail = +"expected: #{expected.inspect}\n  actual: #{actual.inspect}"
  detail = "#{message}\n#{detail}" if message
  raise AssertionFailure, detail
end

def assert_nil(actual, message = nil)
  assert_equal(nil, actual, message)
end

def new_swiss
  SwissHash::Hash.new
end

def assert_hash_like_snapshot(expected_hash, actual_hash, message = nil)
  actual_snapshot = actual_hash.to_h
  assert_equal(expected_hash, actual_snapshot, message || "SwissHash snapshot diverged from Ruby Hash semantics")
  assert_equal(expected_hash.size, actual_hash.size, "size must match Ruby Hash-compatible snapshot")
end

test "mutating original string after insert must not move or corrupt the stored key" do
  key = mutable_string("alpha")
  h = new_swiss
  h[key] = :value

  key << "-mutated"

  assert_equal(:value, h["alpha"], "lookup by original string content must still work")
  assert_nil(h[key], "lookup by the mutated original object must not hit the old entry")
  assert(h.key?("alpha"), "key? must see the original stable string key")
  refute(h.key?(key), "key? must not see the mutated original object as the old key")
  assert_hash_like_snapshot({ "alpha" => :value }, h)

  stored_key = h.keys.first
  assert_equal("alpha", stored_key, "stored key must remain the original content")
  assert(stored_key.frozen?, "stored String key should be frozen/stable like Ruby Hash")
end

test "delete after original string mutation must delete by original content, not mutated object" do
  key = mutable_string("delete-me")
  h = new_swiss
  h[key] = 123

  key.upcase!

  assert_nil(h.delete(key), "delete using mutated object should miss")
  assert_equal(123, h.delete("delete-me"), "delete using original content should return the stored value")
  assert_equal(0, h.size, "hash must be empty after deleting the original key")
  assert_hash_like_snapshot({}, h)
end

test "mutating one key into another existing key must not create duplicate/corrupt visible keys" do
  a = mutable_string("dup-a")
  b = mutable_string("dup-b")
  h = new_swiss
  h[a] = 1
  h[b] = 2

  a.replace("dup-b")

  assert_equal(1, h["dup-a"], "original first key must remain reachable")
  assert_equal(2, h["dup-b"], "second key must remain reachable")
  assert_hash_like_snapshot({ "dup-a" => 1, "dup-b" => 2 }, h)
  assert_equal(%w[dup-a dup-b], h.keys.sort, "visible keys must remain stable")
end

test "mutating a key after table growth must not orphan the entry" do
  keys = Array.new(2_000) { |i| mutable_string("growth-key-#{i}") }
  h = new_swiss
  keys.each_with_index { |key, i| h[key] = i }

  keys[777].replace("growth-key-evil")

  assert_equal(777, h["growth-key-777"], "entry must remain reachable by original content after growth")
  assert_nil(h["growth-key-evil"], "mutated content must not become a key accidentally")
  assert(h.key?("growth-key-777"), "key? must still find the original content")
  refute(h.key?("growth-key-evil"), "key? must not find the mutated content")
  assert_equal(2_000, h.size, "mutation of external object must not change size")
end

test "stored keys returned by each must be stable after external mutation" do
  key = mutable_string("iter-key")
  h = new_swiss
  h[key] = :iter_value

  key.replace("iter-key-mutated")

  yielded = []
  h.each { |k, v| yielded << [k, v] }

  assert_equal([["iter-key", :iter_value]], yielded, "each must yield the stable stored key/value pair")
  assert(yielded.first.first.frozen?, "each should yield a frozen/stable String key")
end

failures = []

puts "Running #{TESTS.length} string-key mutation regression tests..."

TESTS.each do |test_case|
  print "- #{test_case.name}... "
  begin
    test_case.body.call
    puts "ok"
  rescue Exception => e # rubocop:disable Lint/RescueException
    puts "FAIL"
    failures << [test_case.name, e]
  end
end

if failures.any?
  warn "\n#{failures.length} failure(s):"
  failures.each_with_index do |(name, error), i|
    warn "\n#{i + 1}) #{name}"
    warn "#{error.class}: #{error.message}"
    backtrace = error.backtrace&.grep(/string_key_mutation_test\.rb/)&.first(5)
    warn backtrace.join("\n") if backtrace && !backtrace.empty?
  end
  exit 1
end

puts "\nAll string-key mutation regression tests passed."
