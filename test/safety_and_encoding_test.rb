# frozen_string_literal: true

# Safety and Hash-compatibility regressions:
#   - reentrant #hash / #eql? must raise, not UAF
#   - GC during rehash must not crash
#   - exception during rehash must leave the table intact
#   - 7-bit strings of different encodings are one key, like Ruby Hash
#
# Run:
#   bundle exec ruby test/safety_and_encoding_test.rb

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
  raised = nil
  begin
    yield
  rescue error_class => e
    raised = e
  end
  raise AssertionFailure, (message || "expected #{error_class} to be raised") unless raised

  raised
end

class GCKey
  attr_reader :n

  def initialize(n)
    @n = n
  end

  def hash
    GC.start
    @n.hash
  end

  def eql?(other)
    other.is_a?(GCKey) && other.n == @n
  end
end

class MutatingKey
  def initialize(table)
    @table = table
  end

  def hash
    @table[:side] = :mutated
    123
  end

  def eql?(other)
    other.is_a?(MutatingKey)
  end
end

class BoomOnFlag
  def initialize(n, flag)
    @n = n
    @flag = flag
  end

  def hash
    raise "rehash boom" if @flag[:boom] && @n.zero?
    @n.hash
  end

  def eql?(other)
    other.is_a?(BoomOnFlag) && other.instance_variable_get(:@n) == @n
  end
end

test "reentrant insert from #hash raises instead of corrupting the table" do
  h = SwissHash::Hash.new
  h[:keep] = 1
  error = assert_raises(RuntimeError) { h[MutatingKey.new(h)] = :x }
  assert(error.message.include?("reentrant"), "message should mention reentrant modification: #{error.message}")
  assert_equal(1, h[:keep])
  assert_nil(h[:side])
end

test "GC during custom-key rehash does not lose entries" do
  h = SwissHash::Hash.new
  2_000.times { |i| h[GCKey.new(i)] = i }
  2_000.times { |i| assert_equal(i, h[GCKey.new(i)], "missing #{i} after GC-heavy rehash") }
  assert_equal(2_000, h.size)
end

test "exception during rehash keeps the previous table" do
  flag = { boom: false }
  h = SwissHash::Hash.new
  64.times { |i| h[BoomOnFlag.new(i, flag)] = i }

  flag[:boom] = true
  assert_raises(RuntimeError) do
    2_000.times { |i| h[BoomOnFlag.new(1_000 + i, flag)] = i }
  end

  flag[:boom] = false
  64.times { |i| assert_equal(i, h[BoomOnFlag.new(i, flag)], "entry #{i} lost after failed rehash") }
end

test "7-bit UTF-8 and BINARY strings are the same key, like Ruby Hash" do
  utf = "abc"
  bin = "abc".b
  ruby = {}
  ruby[utf] = 1

  h = SwissHash::Hash.new
  h[utf] = 1

  assert_equal(ruby[bin], h[bin], "lookup by BINARY 7-bit string must match Ruby Hash")
  assert_equal(1, h.size)
  assert(h.key?(bin), "key? must treat 7-bit BINARY as the UTF-8 key")
end

test "non-ASCII strings of different encodings stay distinct, like Ruby Hash" do
  utf = "я".dup.force_encoding(Encoding::UTF_8)
  bin = "я".dup.force_encoding(Encoding::ASCII_8BIT)
  ruby = {}
  ruby[utf] = :utf
  ruby[bin] = :bin

  h = SwissHash::Hash.new
  h[utf] = :utf
  h[bin] = :bin

  assert_equal(ruby[utf], h[utf])
  assert_equal(ruby[bin], h[bin])
  assert_equal(ruby.size, h.size)
end

test "re-initialize replaces the table instead of leaking the old one" do
  h = SwissHash::Hash.new
  h[:a] = 1
  h.send(:initialize, 32)
  assert_equal(0, h.size)
  h[:b] = 2
  assert_equal(2, h[:b])
  assert_nil(h[:a])
end

failures = []

puts "Running #{TESTS.length} safety and encoding tests..."

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
  puts "\nAll safety and encoding tests passed."
else
  warn "\n#{failures.length} failure(s):"
  failures.each_with_index do |(test_case, error), index|
    warn "\n#{index + 1}) #{test_case.name}"
    warn "#{error.class}: #{error.message}"
    warn error.backtrace.first(12).join("\n")
  end
  exit 1
end
