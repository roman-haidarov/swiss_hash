# frozen_string_literal: true

# Targeted smoke tests for Hash-like convenience API.
# Run:
#   bundle exec ruby test/hash_api_test.rb

require_relative "../lib/swiss_hash"

class AssertionFailure < StandardError; end

TestCase = Struct.new(:name, :body, keyword_init: true)
TESTS = []

def test(name, &body)
  TESTS << TestCase.new(name: name, body: body)
end

def assert(condition, message)
  raise AssertionFailure, message unless condition
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

def assert_raises(error_class, message = nil)
  raised = false
  begin
    yield
  rescue error_class
    raised = true
  end
  raise AssertionFailure, (message || "expected #{error_class} to be raised") unless raised
end

def sh(hash = {})
  SwissHash::Hash.new.merge!(hash)
end

test "to_h, to_sh, to_a and dup return useful snapshots/copies" do
  h = sh("a" => 1, "b" => nil)

  assert_equal({ "a" => 1, "b" => nil }, h.to_h)
  assert_equal([["a", 1], ["b", nil]].sort_by(&:first), h.to_a.sort_by(&:first))

  copy = h.to_sh
  assert(copy.is_a?(SwissHash::Hash), "to_sh must return SwissHash::Hash")
  assert_equal(h.to_h, copy.to_h)
  copy["a"] = 10
  assert_equal(1, h["a"], "copy mutation must not mutate original")

  duped = h.dup
  duped["c"] = 3
  assert_nil(h["c"], "dup mutation must not mutate original")
end

test "each_pair, each_key and each_value match Hash-style iteration" do
  h = sh(:a => 1, :b => 2, :c => 3)

  assert_equal(h.to_h, h.each_pair.to_h)
  assert_equal(%i[a b c], h.each_key.to_a.sort)
  assert_equal([1, 2, 3], h.each_value.to_a.sort)

  yielded = []
  h.each_key { |key| yielded << key }
  assert_equal(%i[a b c], yielded.sort)
end

test "merge, merge!, update, replace and merge block work" do
  h = sh(:a => 1, :b => 2)

  assert_equal({ :a => 1, :b => 2 }, h.merge.to_h, "merge without args returns a copy")
  assert_equal(h, h.merge!, "merge! without args returns self")

  merged = h.merge({ :b => 20, :c => 30 }, { :c => 300, :d => 400 })
  assert_equal({ :a => 1, :b => 2 }, h.to_h, "merge must not mutate receiver")
  assert_equal({ :a => 1, :b => 20, :c => 300, :d => 400 }, merged.to_h)

  h.merge!({ :b => 3, :c => 4 }, { :b => 30 }) { |_key, old_value, new_value| old_value + new_value }
  assert_equal({ :a => 1, :b => 35, :c => 4 }, h.to_h)

  h.update(:d => 5)
  assert_equal(5, h[:d])

  h.replace(:x => 9)
  assert_equal({ :x => 9 }, h.to_h)
end

test "fetch, fetch_values, values_at, key? and value? behave like Hash" do
  h = sh("a" => 1, "b" => nil)

  assert_equal(1, h.fetch("a"))
  assert_nil(h.fetch("b"))
  assert_equal(:fallback, h.fetch("missing", :fallback))
  assert_equal("missing!", h.fetch("missing") { |key| "#{key}!" })
  assert_raises(KeyError) { h.fetch("missing") }

  assert_equal([1, nil, nil], h.values_at("a", "b", "missing"))
  assert_equal([1, :fallback], h.fetch_values("a", "missing") { :fallback })
  assert(h.key?("a"), "key? must find existing key")
  assert(h.has_key?("a"), "has_key? must find existing key")
  assert(h.member?("a"), "member? must find existing key")
  assert(h.value?(1), "value? must find existing value")
  assert(h.has_value?(nil), "has_value? must find nil value")
  assert_equal("a", h.key(1))
end

test "slice, except, invert, select, reject and compact are Hash-like" do
  h = sh(:a => 1, :b => nil, :c => 3)

  assert_equal({ :a => 1, :b => nil }, h.slice(:a, :b, :missing).to_h)
  assert_equal({ :a => 1, :c => 3 }, h.except(:b).to_h)
  assert_equal({ 1 => :a, nil => :b, 3 => :c }, h.invert.to_h)
  assert_equal({ :a => 1, :c => 3 }, h.select { |_key, value| value }.to_h)
  assert_equal({ :b => nil }, h.reject { |_key, value| value }.to_h)
  assert_equal({ :a => 1, :c => 3 }, h.compact.to_h)
  assert_equal({ :a => 1, :b => nil, :c => 3 }, h.to_h, "non-bang methods must not mutate")

  assert_equal(h, h.compact!)
  assert_equal({ :a => 1, :c => 3 }, h.to_h)
  assert_nil(h.compact!, "compact! returns nil when unchanged")
end


test "dig, assoc, rassoc, shift and transform methods are available" do
  h = sh(:a => { :nested => 1 }, :b => 2, :c => 3)

  assert_equal(1, h.dig(:a, :nested))
  assert_nil(h.dig(:missing, :nested))
  assert_equal([:b, 2], h.assoc(:b))
  assert_equal([:c, 3], h.rassoc(3))
  shifted = h.shift
  assert([[:a, { :nested => 1 }], [:b, 2], [:c, 3]].include?(shifted), "shift must return one key/value pair")
  ref_hash = { :a => { :nested => 1 }, :b => 2, :c => 3 }
  ref_hash.delete(shifted.first)
  assert_equal(ref_hash, h.to_h)

  transformed = h.transform_values { |value| value.is_a?(::Hash) ? value : value * 10 }
  assert_equal(ref_hash.transform_values { |value| value.is_a?(::Hash) ? value : value * 10 }, transformed.to_h)

  h.transform_values! { |value| value.is_a?(::Hash) ? value : value + 1 }
  ref_hash.transform_values! { |value| value.is_a?(::Hash) ? value : value + 1 }
  assert_equal(ref_hash, h.to_h)

  assert_equal(ref_hash.transform_keys(&:to_s), h.transform_keys(&:to_s).to_h)
  h.transform_keys!(&:to_s)
  assert_equal(ref_hash.transform_keys(&:to_s), h.to_h)
  assert_equal(h.to_a.flatten(1), h.flatten(1))
end

puts "Running #{TESTS.length} Hash-like API tests..."
failures = []

TESTS.each do |test_case|
  print "- #{test_case.name}... "
  begin
    test_case.body.call
    puts "ok"
  rescue Exception => e # rubocop:disable Lint/RescueException
    puts "FAIL"
    failures << [test_case, e]
  end
end

if failures.empty?
  puts "\nAll Hash-like API tests passed."
else
  warn "\n#{failures.length} failure(s):"
  failures.each_with_index do |(test_case, error), index|
    warn "\n#{index + 1}) #{test_case.name}"
    warn "#{error.class}: #{error.message}"
    warn error.backtrace.join("\n")
  end
  exit 1
end
